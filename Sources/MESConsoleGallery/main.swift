import AppKit
import Foundation
import MESCore
import MESEngineKit
import MESEngineUI
import MockEngineCore
import SwiftUI

// mes-console-gallery: MESEngineUI's console over the mock engine, with a job submitted every few seconds, so the Queue,
// the Models' enabled set, the Plugins page, the System page and the menu-bar item can be seen without real models. It's
// also the smallest worked example of an engine app: a server, an enabled set, a backend, the window and the menu-bar
// item. Its models come in mock plugins (MockPlugins.swift), as Gaea's do, and two real worker processes hold memory, so
// the System page sums a host and its workers.
//
//     swift run mes-console-gallery
//     swift run mes-console-gallery --snapshot /tmp/console   # renders the pages to PNGs offscreen, then quits

/// The mock engine behind an enabled set, as a real engine's `descriptors()` honours one: a model is offered when it's
/// on and its plugin is on and trusted.
struct EnabledMockEngine: MediaEngine {
    let inner: MockImageEngine
    let enablement: ModelEnablement
    let plugins: MockPluginStore

    func descriptors() async -> [Descriptor] {
        await inner.descriptors().compactMap { descriptor in
            var d = descriptor
            d.models = d.models.filter { enablement.isEnabled($0.id, optIn: $0.namedOnly == true) && plugins.runs($0.id) }
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
    let plugins: MockPluginStore

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
                    let plugin = plugins.plugin(of: offer.id)
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
                        tags: optIn ? ["Work in progress"] : [],
                        plugin: plugin.map { EngineModel.Plugin(id: $0.id, title: $0.title) }, version: plugin?.version,
                        update: plugin?.update)
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
    private var workers: [(process: Process, plugin: EnginePlugin)] = []
    /// `--snapshot <dir>`: render the pages offscreen into `dir`, then quit.
    private let snapshotDirectory: URL? = CommandLine.arguments.firstIndex(of: "--snapshot").flatMap { i in
        i + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[i + 1]) : nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        let pluginStore = MockPluginStore()
        // One worker per plugin, as Gaea runs them, each holding some memory; the System page reads them by pid.
        workers = MockWorkers.start(pluginStore.plugins.enumerated().map { ($1, [640, 1536][$0 % 2]) })
        let workerList = workers.map { ($0.process.processIdentifier, $0.plugin) }
        system.processSource = .processes {
            [EngineProcess.current(title: "MES Mock Engine")]
                + workerList.map { pid, plugin in
                    EngineProcess(id: plugin.id, title: plugin.title, detail: plugin.models.joined(separator: ", "), pid: pid)
                }
        }
        if snapshotDirectory == nil {
            let window = EngineConsoleWindowController(console: console, system: system, menuBar: menuBar)
            self.window = window
            statusItem = EngineStatusItemController(console: console, system: system, menuBar: menuBar) { window.show($0) }
            window.show(.queue)
        }

        let engine = MockImageEngine(stepDelay: .milliseconds(250), steps: 24)
        let enablement = ModelEnablement(file: nil)
        var config = EngineConfiguration(id: "eng_gallery", name: "MES Mock Engine", implementationName: "mes-console-gallery",
                                         implementationVersion: "0.3.0",
                                         spoolDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("mes-console-gallery"))
        config.advertise = false
        config.handlesShutdownSignals = false
        let server = MESEngineServer(engine: EnabledMockEngine(inner: engine, enablement: enablement, plugins: pluginStore),
                                     configuration: config)
        let backend = MockConsoleBackend(server: server, engine: engine, enablement: enablement, plugins: pluginStore)
        let pluginBackend = MockPluginBackend(store: pluginStore) { await server.reloadDescriptors() }
        let console = self.console
        let snapshotDirectory = self.snapshotDirectory
        Task {
            do {
                try await server.run { port in
                    await MainActor.run {
                        console.endpoint = "http://127.0.0.1:\(port)/mes/v0"
                        console.modeSummary = "Open mode · this Mac only"
                        console.attach(backend, plugins: pluginBackend)
                    }
                    Task { await Self.submitJobs(port: port) }
                    if let snapshotDirectory {
                        Task { @MainActor in await self.renderSnapshots(to: snapshotDirectory) }
                    }
                }
            } catch {
                await MainActor.run { console.status = .failed("\(error)") }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        for worker in workers { worker.process.terminate() }
    }

    /// Renders the console's pages offscreen (no screen recording needed) as `<dir>/<page>-<appearance>.png`.
    private func renderSnapshots(to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await console.refreshModels()
        await console.refreshPlugins()
        await system.sampleNow()
        try? await Task.sleep(for: .seconds(1))
        await system.sampleNow()
        let pages: [(String, () -> Void)] = [
            ("plugins", { self.console.section = .plugins }),
            ("models", { self.console.section = .models; self.console.selectedModelID = "mock-research" }),
            ("system-memory", { self.console.section = .system; self.system.tab = .memory }),
        ]
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, select) in pages {
                select()
                // The window's own background doesn't draw offscreen, so the snapshot paints it.
                let view = NSHostingView(rootView: EngineConsoleView(console: console, system: system, menuBar: menuBar)
                    .background(Color(nsColor: .windowBackgroundColor)))
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 1320, height: 1000)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: appearance)
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(800))
                view.layoutSubtreeIfNeeded()
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let suffix = appearance == .aqua ? "light" : "dark"
                let file = directory.appendingPathComponent("console-\(name)-\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: file)
                print("wrote \(file.path)")
            }
        }
        NSApp.terminate(nil)
    }

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

MockWorkers.runIfWorker()
let app = NSApplication.shared
let delegate = GalleryDelegate()
app.delegate = delegate
app.run()
