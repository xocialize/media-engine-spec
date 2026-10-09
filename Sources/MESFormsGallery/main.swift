import AppKit
import DesignScaffold
import MESCore
import MESFormsUI
import MockEngineCore
import SwiftUI

// mes-forms-gallery: every mock descriptor's form (R0c exit: "a MESFormsUI preview renders every mock descriptor").
//
//   mes-forms-gallery                     a window: operations on the left, the form, and the request it makes
//   mes-forms-gallery --snapshot <dir>    each form as PNG, light and dark, with advanced fields and extensions open

// Synchronous top-level code on purpose: `app.run()` from inside an async main's main-actor job never services the
// main queue (GCD doesn't re-enter it), so SwiftUI never draws. The descriptors load off the main thread first.
final class DescriptorBox: @unchecked Sendable { var value: [Descriptor] = [] }
let arguments = CommandLine.arguments
let descriptors: [Descriptor] = {
    let box = DescriptorBox()
    let done = DispatchSemaphore(value: 0)
    Task.detached { box.value = await MockImageEngine().descriptors(); done.signal() }
    done.wait()
    return box.value
}()

/// A form with everything showing: advanced open, extensions on, a prompt typed.
@MainActor func showcase(_ d: Descriptor) -> OperationFormModel {
    let form = OperationFormModel(descriptor: d)
    form.showsAdvanced = true
    for spec in form.textInputs where spec.required { form.text[spec.name] = "a lighthouse at dusk" }
    for ext in d.extensions ?? [] { form.setEnabled(ext, true) }
    for field in form.fields {                                   // show a oneOf's first variant, fields and all
        if case .choice(let variants) = field.widget, let first = variants.first {
            form.setValue(FormSchema.initialValue(first.schema), at: [field.name])
        }
    }
    return form
}

@MainActor func snapshot(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for d in descriptors {
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let root = OperationFormContent(form: showcase(d))
                .padding(Tokens.Space.l)
                .frame(width: Tokens.Layout.inspectorWidth + 2 * Tokens.Space.l)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: root)
            host.appearance = NSAppearance(named: appearance)
            let window = SnapshotWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless],
                                        backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            // Text editors settle their height after the first layout pass, so measure again before drawing.
            for _ in 0..<3 {
                window.setContentSize(host.fittingSize)
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = directory.appendingPathComponent("\(d.operation)-\(suffix).png")
            try rep.representation(using: .png, properties: [:])?.write(to: file)
            print("\(file.lastPathComponent)  \(Int(host.bounds.width))×\(Int(host.bounds.height))")
        }
    }
}

/// An offscreen window that may be taller than the screen (AppKit otherwise clamps it, cropping tall forms).
final class SnapshotWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct GalleryView: View {
    let forms: [OperationFormModel]
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(forms, id: \.descriptor.operation, selection: $selection) { form in
                VStack(alignment: .leading, spacing: 2) {
                    Text(form.descriptor.title)
                    Text(form.descriptor.operation).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            .navigationSplitViewColumnWidth(Tokens.Layout.sidebarWidth)
        } detail: {
            if let form = forms.first(where: { $0.descriptor.operation == selection }) {
                HStack(spacing: 0) {
                    OperationForm(form: form).frame(width: Tokens.Layout.inspectorWidth + 2 * Tokens.Space.l)
                    Divider()
                    RequestPreview(form: form)
                }
            } else {
                Text("Choose an operation").foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .onAppear { selection = forms.first?.descriptor.operation }
    }
}

/// The request the form makes right now, and what's still missing or invalid.
struct RequestPreview: View {
    let form: OperationFormModel

    var body: some View {
        let media = Dictionary(uniqueKeysWithValues: form.mediaInputs.map { ($0.name, RequestInput.one(.upload("upl_example"))) })
        let request = form.request(media: media)
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                SectionHeader("Request")
                Text((try? String(decoding: prettyEncoder.encode(request), as: UTF8.self)) ?? "")
                    .font(Tokens.Font.mono).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Tokens.Space.m).cardSurface()
                let issues = form.issues
                if !issues.isEmpty {
                    SectionHeader("Problems")
                    ForEach(issues.sorted(by: { $0.key < $1.key }), id: \.key) { key, message in
                        Text("\(key): \(message)").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure)
                    }
                }
            }
            .padding(Tokens.Space.l)
        }
        .frame(minWidth: 320)
    }

    var prettyEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

if let i = arguments.firstIndex(of: "--snapshot") {
    let directory = URL(fileURLWithPath: arguments.indices.contains(i + 1) ? arguments[i + 1] : "form-snapshots", isDirectory: true)
    try snapshot(to: directory)
    exit(0)
}

/// Quits with the window, and gives the app a Quit item.
final class GalleryDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

do {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = GalleryDelegate()
    app.delegate = delegate
    let menu = NSMenu()
    let appItem = NSMenuItem()
    appItem.submenu = NSMenu()
    appItem.submenu?.addItem(NSMenuItem(title: "Quit MESFormsUI Gallery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    menu.addItem(appItem)
    app.mainMenu = menu
    let forms = descriptors.map(OperationFormModel.init(descriptor:))
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.title = "MESFormsUI gallery"
    window.contentView = NSHostingView(rootView: GalleryView(forms: forms))
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate()
    withExtendedLifetime(delegate) { app.run() }
}
