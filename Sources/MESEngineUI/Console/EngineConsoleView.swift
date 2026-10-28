import AppKit
import DesignScaffold
import DesignScaffoldStatus
import SwiftUI

/// An engine's console window: a sidebar of sections (Queue, Models, Plugins when the engine has them, System) with the
/// engine's status and address, and the selected section beside it.
public struct EngineConsoleView: View {
    @Bindable var console: EngineConsoleModel
    let system: SystemMonitorStore
    let menuBar: MenuBarPreferences

    public init(console: EngineConsoleModel, system: SystemMonitorStore, menuBar: MenuBarPreferences) {
        self.console = console
        self.system = system
        self.menuBar = menuBar
    }

    public var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Tokens.Layout.minWindowWidth, minHeight: Tokens.Layout.minWindowHeight)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: console.info.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tokens.Color.accent)
                VStack(alignment: .leading, spacing: 0) {
                    Text(console.info.name).font(Tokens.Font.headline).lineLimit(2)
                    Text("MES \(console.info.profile) · \(console.info.version)")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            .padding(.horizontal, Tokens.Space.m)
            .padding(.top, Tokens.Space.s)
            .padding(.bottom, Tokens.Space.m)
            List(selection: Binding(get: { console.section }, set: { if let s = $0 { console.section = s } })) {
                ForEach(console.sections) { section in
                    Label(section.title, systemImage: section.symbol)
                        .badge(badge(section))
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            statusCard.padding(Tokens.Space.m)
        }
    }

    private func badge(_ section: ConsoleSection) -> Text? {
        switch section {
        case .queue:
            let count = console.activity.running.count + console.activity.upcoming.count
            return count > 0 ? Text("\(count)") : nil
        case .models:
            return console.models.isEmpty ? nil : Text("\(console.enabledCount)")
        case .plugins:
            return console.updatesAvailable > 0 ? Text("\(console.updatesAvailable)") : nil
        case .system:
            return nil
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            StatusPill(statusLabel, status: pillStatus)
            if let endpoint = console.endpoint {
                HStack(spacing: 4) {
                    Text(endpoint).font(Tokens.Font.monoSmall).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(endpoint, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy the engine's address")
                }
            }
            if let mode = console.modeSummary {
                Text(mode).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    private var statusLabel: String {
        switch console.status {
        case .starting(let message): message
        case .failed: "Stopped"
        case .serving:
            console.activity.running.isEmpty ? "Serving" : "Working · \(console.activity.upcoming.count) waiting"
        }
    }

    private var pillStatus: Status {
        switch console.status {
        case .starting: .working()
        case .failed: .failed
        case .serving: console.activity.running.isEmpty ? .ready : .working()
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if case .failed(let message) = console.status {
            ConsoleEmptyState(symbol: "exclamationmark.octagon", title: "The engine stopped", message: message)
        } else {
            switch console.section {
            case .queue: EngineQueueView(console: console)
            case .models: EngineModelsView(console: console)
            case .plugins: EnginePluginsView(console: console)
            case .system: SystemMonitorView(store: system, menuBar: menuBar)
            }
        }
    }
}

/// The console's window, made in code so the menu-bar item can bring it back after it's closed. While it's open the
/// app shows in the Dock and the app switcher; closed, the engine keeps serving from the menu bar.
@MainActor
public final class EngineConsoleWindowController: NSObject, NSWindowDelegate {
    private let console: EngineConsoleModel
    private let system: SystemMonitorStore
    private let menuBar: MenuBarPreferences
    private var window: NSWindow?

    public init(console: EngineConsoleModel, system: SystemMonitorStore, menuBar: MenuBarPreferences) {
        self.console = console
        self.system = system
        self.menuBar = menuBar
    }

    /// Shows the window (making it if needed), on `section` if given.
    public func show(_ section: ConsoleSection? = nil) {
        if let section { console.section = section }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public var isVisible: Bool { window?.isVisible == true }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = console.info.name
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: EngineConsoleView(console: console, system: system, menuBar: menuBar))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = NSSize(width: Tokens.Layout.minWindowWidth, height: Tokens.Layout.minWindowHeight)
        // After the content, which sizes the window to its minimum: a saved frame, or a roomy first one.
        if !window.setFrameUsingName("MESEngineUI.Console") {
            window.setContentSize(NSSize(width: 1320, height: 860))
            window.center()
        }
        window.setFrameAutosaveName("MESEngineUI.Console")
        window.delegate = self
        return window
    }

    public func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar app; the engine keeps serving.
        NSApp.setActivationPolicy(.accessory)
    }
}
