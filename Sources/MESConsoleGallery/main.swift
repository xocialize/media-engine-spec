import AppKit
import Foundation
import MESCore
import MESEngineKit
import MESEngineUI
import MockEngineCore
import SwiftUI

// mes-console-gallery: MESEngineUI's console over the mock engine, with a job submitted every few seconds, so the Queue,
// the Models' enabled set, the System page and the menu-bar item can be seen without real models. It's also the smallest
// worked example of an engine app: a server, an enabled set, a backend, the window and the menu-bar item.
//
//     swift run mes-console-gallery

/// The mock engine behind an enabled set, as a real engine's `descriptors()` honours one.
struct EnabledMockEngine: MediaEngine {
    let inner: MockImageEngine
    let enablement: ModelEnablement

    func descriptors() async -> [Descriptor] {
        await inner.descriptors().compactMap { descriptor in
            var d = descriptor
            d.models = d.models.filter { enablement.isEnabled($0.id, optIn: $0.namedOnly == true) }
            return d.models.isEmpty ? nil : d
        }
    }

    func run(_ context: RunContext) async throws -> RunOutput { try await inner.run(context) }
}

/// The console's view of the mock engine: the server's operator API, and models made from the mock's offers.
struct MockConsoleBackend: EngineConsoleBackend {
    let server: MESEngineServer
    let engine: MockImageEngine
    let enablement: ModelEnablement

    func activity() -> AsyncStream<EngineActivity> { server.activity() }
    func cancel(job id: String) async throws { try await server.cancel(job: id) }
    func operations() async -> [Descriptor] { await server.operations() ?? [] }

    func models() async -> [EngineModel] {
        let all = await engine.descriptors()
        let live = await operations()
        var byID: [String: EngineModel] = [:]
        for descriptor in all {
            for offer in descriptor.models {
                let optIn = offer.namedOnly == true
                let isDefault = live.first { $0.operation == descriptor.operation }?.models
                    .contains { $0.id == offer.id && $0.isDefault == true } ?? false
                let role = EngineModel.Role(operation: descriptor.operation, qualityTiers: offer.qualityTiers,
                                            isDefault: isDefault, namedOnly: optIn)
                if byID[offer.id] == nil {
                    byID[offer.id] = EngineModel(
                        id: offer.id, title: offer.title.hasPrefix("Mock image") ? "Mock Image Model" : offer.title,
                        summary: optIn ? "A stand-in for a research-licensed model: offered only when named."
                            : "Synthetic, rule-abiding results for every Image operation (CoreGraphics).",
                        license: offer.license, optIn: optIn, enabled: enablement.isEnabled(offer.id, optIn: optIn),
                        acceptedAt: enablement.acceptedAt(offer.id), notes: offer.notes ?? (optIn ? nil
                            : "Prompts are ignored; sizes snap to multiples of 16."),
                        memoryClass: offer.memoryClass, speedClass: offer.speedClass,
                        footprintBytes: optIn ? 9 << 30 : 512 << 20, install: optIn ? .notDownloaded(bytes: 6 << 30) : .builtIn,
                        resident: !optIn, source: optIn ? "example/mock-research" : nil,
                        sourceURL: optIn ? URL(string: "https://huggingface.co/example/mock-research") : nil,
                        tags: optIn ? ["Work in progress"] : [])
                }
                byID[offer.id]?.roles.append(role)
            }
        }
        return byID.values.sorted { ($0.optIn ? 1 : 0, $0.title) < ($1.optIn ? 1 : 0, $1.title) }
    }

    func setEnabled(_ enabled: Bool, model id: String) async throws {
        let optIn = await models().first { $0.id == id }?.optIn ?? false
        try enablement.set(id, enabled: enabled, optIn: optIn)
        await server.reloadDescriptors()
    }

    func download(model id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        for step in 1...20 {
            try await Task.sleep(for: .milliseconds(100))
            progress(Double(step) / 20)
        }
    }
}

@MainActor
final class GalleryDelegate: NSObject, NSApplicationDelegate {
    private let console = EngineConsoleModel(info: EngineConsoleInfo(name: "MES Mock Engine", profile: "Image",
                                                                     symbol: "photo.stack", version: "gallery"))
    private let system = SystemMonitorStore()
    private let menuBar = MenuBarPreferences()
    private var window: EngineConsoleWindowController?
    private var statusItem: EngineStatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let window = EngineConsoleWindowController(console: console, system: system, menuBar: menuBar)
        self.window = window
        statusItem = EngineStatusItemController(console: console, system: system, menuBar: menuBar) { window.show($0) }
        window.show(.queue)

        let engine = MockImageEngine(stepDelay: .milliseconds(250), steps: 24)
        let enablement = ModelEnablement(file: nil)
        var config = EngineConfiguration(id: "eng_gallery", name: "MES Mock Engine", implementationName: "mes-console-gallery",
                                         implementationVersion: "0.3.0",
                                         spoolDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mes-console-gallery"))
        config.advertise = false
        config.handlesShutdownSignals = false
        let server = MESEngineServer(engine: EnabledMockEngine(inner: engine, enablement: enablement), configuration: config)
        let backend = MockConsoleBackend(server: server, engine: engine, enablement: enablement)
        let console = self.console
        Task {
            do {
                try await server.run { port in
                    await MainActor.run {
                        console.endpoint = "http://127.0.0.1:\(port)/mes/v0"
                        console.modeSummary = "Open mode · this Mac only"
                        console.attach(backend)
                    }
                    Task { await Self.submitJobs(port: port) }
                }
            } catch {
                await MainActor.run { console.status = .failed("\(error)") }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A few jobs to begin with, then one every few seconds, so the queue has a running job and some waiting.
    private static func submitJobs(port: Int) async {
        let prompts = ["a lighthouse at dusk, long exposure", "a red fox in fresh snow", "a tiny robot watering a bonsai",
                       "an isometric city block at night", "a bowl of ramen, top-down, studio light"]
        let png = Self.samplePNG()
        var index = 0
        while !Task.isCancelled {
            let request: JobRequest
            switch index % 3 {
            case 0: request = JobRequest(operation: "image.generate", inputs: ["prompt": .text(prompts[index % prompts.count])],
                                         params: ["quality": .string(["draft", "standard", "best"][index % 3])])
            case 1: request = JobRequest(operation: "image.upscale", inputs: ["image": .one(.inline(mediaType: "image/png", data: png))])
            default: request = JobRequest(operation: "image.restore", inputs: ["image": .one(.inline(mediaType: "image/png", data: png))])
            }
            var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mes/v0/jobs")!)
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.httpBody = try? MESJSON.encoder.encode(request)
            _ = try? await URLSession.shared.data(for: http)
            index += 1
            try? await Task.sleep(for: .seconds(index < 4 ? 0.5 : 9))
        }
    }

    /// A 64×64 gradient, the input of the upscale and restore jobs.
    private static func samplePNG() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<64 {
            for x in 0..<64 {
                rep.setColor(NSColor(red: CGFloat(x) / 63, green: CGFloat(y) / 63, blue: 0.6, alpha: 1), atX: x, y: y)
            }
        }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MES Console Gallery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}

let app = NSApplication.shared
let delegate = GalleryDelegate()
app.delegate = delegate
app.run()
