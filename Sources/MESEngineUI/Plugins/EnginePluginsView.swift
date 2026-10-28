import AppKit
import DesignScaffold
import MESCore
import SwiftUI

/// The Plugins section, for engines whose models come as plugins (Gaea): add a plugin by its Git repo URL, see its
/// version and whether a release is newer, update it or roll it back, switch it or any of its models on and off, and
/// manage the teams whose signatures the engine trusts.
struct EnginePluginsView: View {
    @Bindable var console: EngineConsoleModel
    @State private var addingPlugin = false
    @State private var pendingRemoval: EnginePlugin?
    @State private var pendingRevocation: EngineTeam?
    @State private var pendingOptIn: EngineModel?

    var body: some View {
        VStack(spacing: 0) {
            ConsoleSectionHeader(title: "Plugins",
                                 subtitle: "Models come in signed plugins, added from their Git repos.") {
                Text(summary)
                    .font(Tokens.Font.caption.weight(.semibold))
                    .foregroundStyle(Tokens.Color.secondaryLabel)
                Button {
                    console.checkForUpdates()
                } label: {
                    if console.isCheckingForUpdates {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(console.isCheckingForUpdates)
                .help("Read every plugin's repo for newer releases now")
                Button("Add Plugin…", systemImage: "plus") { addingPlugin = true }
                    .buttonStyle(.borderedProminent)
            }
            Separator(.horizontal)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.m) {
                    if console.plugins.isEmpty {
                        ConsoleEmptyState(symbol: "puzzlepiece.extension", title: "No plugins yet",
                                          message: "Add a plugin from its Git repo URL. The engine installs its newest release "
                                              + "once its signature checks out.")
                    }
                    ForEach(console.plugins) { plugin in
                        PluginCard(console: console, plugin: plugin, selected: plugin.id == console.selectedPluginID,
                                   onRemove: { pendingRemoval = plugin }, onToggleModel: { toggle($0, enabled: $1) })
                    }
                    TrustedTeamsCard(teams: console.trustedTeams, onRevoke: { pendingRevocation = $0 })
                        .padding(.top, Tokens.Space.s)
                }
                .padding(Tokens.Space.l)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $addingPlugin) {
            AddPluginSheet(console: console)
        }
        // An add that needs trust asks inside its own sheet; this one is for updates.
        .sheet(item: Binding(get: { addingPlugin ? nil : console.trustPrompt }, set: { console.trustPrompt = $0 })) { request in
            TrustPromptSheet(request: request, onTrust: { console.trust(request) }, onDecline: { console.decline(request) })
        }
        .alert("Remove \(pendingRemoval?.title ?? "")?", isPresented: present($pendingRemoval), presenting: pendingRemoval) { plugin in
            Button("Remove", role: .destructive) { console.remove(plugin: plugin) }
            Button("Cancel", role: .cancel) {}
        } message: { plugin in
            Text("Its \(plugin.models.count == 1 ? "model stops" : "models stop") being offered, and every version on disk is "
                + "deleted. You can add it again from \(plugin.repository.absoluteString).")
        }
        .alert("Stop trusting \(pendingRevocation?.name ?? "")?", isPresented: present($pendingRevocation),
               presenting: pendingRevocation) { team in
            Button("Stop Trusting", role: .destructive) { console.revokeTrust(team: team) }
            Button("Cancel", role: .cancel) {}
        } message: { team in
            Text("Plugins signed by \(team.name) (\(team.id)) stop running until you trust the team again.")
        }
        .alert("Accept \(pendingOptIn?.title ?? "")'s licence?", isPresented: present($pendingOptIn),
               presenting: pendingOptIn) { model in
            Button("Accept and Turn On") { console.setEnabled(true, model: model.id) }
            if let terms = model.license.termsURL.flatMap(URL.init(string:)) {
                Button("View Terms") { NSWorkspace.shared.open(terms) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text((model.license.notice ?? "\(model.title) is licensed \(model.license.spdx).")
                + "\n\nTurning it on means you accept its terms. Requests run it only when they name it.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { console.actionError != nil && console.trustPrompt == nil },
                                                            set: { if !$0 { console.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(console.actionError ?? "")
        }
    }

    private var summary: String {
        let updates = console.updatesAvailable
        let installed = "\(console.plugins.count) installed"
        return updates > 0 ? installed + " · \(updates) update\(updates == 1 ? "" : "s")" : installed
    }

    /// Turning an opt-in model on accepts its terms, so it asks first, as the Models page does.
    private func toggle(_ model: EngineModel, enabled: Bool) {
        if enabled, model.optIn { pendingOptIn = model } else { console.setEnabled(enabled, model: model.id) }
    }

    private func present<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

// MARK: - Plugin card

private struct PluginCard: View {
    let console: EngineConsoleModel
    let plugin: EnginePlugin
    let selected: Bool
    let onRemove: () -> Void
    let onToggleModel: (EngineModel, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            HStack(alignment: .top, spacing: Tokens.Space.m) {
                IconTile(symbol: "puzzlepiece.extension", tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    FlowRow(spacing: 6) {
                        Text(plugin.title).font(Tokens.Font.headline).lineLimit(1)
                        Pill(text: plugin.version, symbol: "tag")
                        ForEach(badges, id: \.text) { Pill(text: $0.text, symbol: $0.symbol, tint: $0.tint) }
                    }
                    Text(plugin.id).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel).textSelection(.enabled)
                    if !plugin.summary.isEmpty {
                        Text(plugin.summary).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(2)
                    }
                    HStack(spacing: Tokens.Space.m) {
                        Link(destination: plugin.repository) {
                            Label(Self.shortRepository(plugin.repository), systemImage: "link")
                        }
                        Label("\(plugin.team.name) (\(plugin.team.id))", systemImage: "checkmark.seal")
                            .foregroundStyle(Tokens.Color.secondaryLabel)
                            .help("The team whose Developer ID signature the engine checked")
                    }
                    .font(Tokens.Font.caption)
                    .lineLimit(1)
                }
                Spacer(minLength: Tokens.Space.m)
                VStack(alignment: .trailing, spacing: Tokens.Space.s) {
                    HStack(spacing: Tokens.Space.s) {
                        Menu {
                            actions
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("More actions for \(plugin.title)")
                        Toggle("On", isOn: Binding(get: { plugin.enabled }, set: { console.setEnabled($0, plugin: plugin.id) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("\(plugin.title) on")
                            .help(plugin.enabled ? "Turn off: none of its models is offered, and its worker stops"
                                : "Turn on: its models are offered again")
                    }
                    workState
                }
            }
            if case .failed(let message) = plugin.state {
                Callout(symbol: "exclamationmark.triangle.fill", tint: Tokens.Color.failure, text: message)
            }
            if let update = plugin.update, console.pluginWork[plugin.id] == nil {
                updateRow(update)
            }
            let models = console.models(of: plugin)
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Models")
                    ForEach(models) { model in
                        PluginModelRow(console: console, model: model, pluginEnabled: plugin.enabled,
                                       onToggle: { onToggleModel(model, $0) })
                    }
                }
            }
        }
        .padding(Tokens.Space.m + 2)
        .background(selected ? Tokens.Color.selectionWash : Tokens.Color.surface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.container))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.container)
                .strokeBorder(selected ? Tokens.Color.accent : Tokens.Color.separator, lineWidth: selected ? 1.5 : 1)
        }
        .opacity(plugin.enabled || selected ? 1 : 0.7)
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        if let update = plugin.update {
            Button("Update to \(update.version)", systemImage: "arrow.down.circle") { console.update(plugin: plugin) }
        }
        if let previous = plugin.rollbackVersion {
            Button("Roll Back to \(previous)", systemImage: "arrow.uturn.backward") { console.rollBack(plugin: plugin) }
        }
        Button("Open Repository", systemImage: "safari") { NSWorkspace.shared.open(plugin.repository) }
        Button("Copy Plugin ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plugin.id, forType: .string)
        }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive, action: onRemove)
    }

    @ViewBuilder private var workState: some View {
        if let progress = console.pluginWork[plugin.id] {
            HStack(spacing: 6) {
                if let progress {
                    ProgressView(value: progress).frame(width: 70)
                    Text(ConsoleFormat.percent(progress)).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Working")
                }
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Color.secondaryLabel)
        } else if let checked = plugin.lastChecked {
            Text("Checked \(checked, format: .relative(presentation: .named))")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.tertiaryLabel)
        }
    }

    private func updateRow(_ update: EngineUpdate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.m) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Tokens.Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(update.version) is available").font(Tokens.Font.body.weight(.semibold))
                if let notes = update.notes, !notes.isEmpty {
                    Text(notes).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(3)
                }
                Text("The engine switches when its models are idle, and keeps \(plugin.version) to roll back to.")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.tertiaryLabel)
            }
            Spacer()
            if let url = update.url {
                Link("Release Notes", destination: url).font(Tokens.Font.caption)
            }
            Button("Update") { console.update(plugin: plugin) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(Tokens.Space.m)
        .background(Tokens.Color.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.control + 2))
    }

    private var tint: Color {
        if case .failed = plugin.state { return Tokens.Color.failure }
        return plugin.enabled ? Tokens.Color.accent : Tokens.Color.secondaryLabel
    }

    private var badges: [(text: String, symbol: String?, tint: Color)] {
        var out: [(String, String?, Color)] = []
        if let update = plugin.update { out.append(("\(update.version) available", "arrow.down.circle", Tokens.Color.accent)) }
        switch plugin.state {
        case .ready: break
        case .updating: out.append(("Updating", "arrow.down.circle", Tokens.Color.working))
        case .pendingSwitch(let version): out.append(("Switches to \(version) when idle", "clock", Tokens.Color.working))
        case .failed: out.append(("Can't run", "exclamationmark.triangle.fill", Tokens.Color.failure))
        }
        if !plugin.enabled { out.append(("Off", "power", Tokens.Color.secondaryLabel)) }
        return out
    }

    /// `owner/repo` for a GitHub URL, else the host and path.
    static func shortRepository(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        let path = parts.joined(separator: "/").replacingOccurrences(of: ".git", with: "")
        return url.host() == "github.com" ? path : "\(url.host() ?? "")/\(path)"
    }
}

/// One of a plugin's models: its switch, where its weights are, and a way to its card on the Models page.
private struct PluginModelRow: View {
    let console: EngineConsoleModel
    let model: EngineModel
    let pluginEnabled: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.m) {
            Image(systemName: OperationSymbol.symbol(model.roles.first?.operation))
                .foregroundStyle(Tokens.Color.secondaryLabel)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.title).font(Tokens.Font.body)
                    if model.optIn { Pill(text: "Opt-in", symbol: "checkmark.seal", tint: Tokens.Color.working) }
                    if model.resident { Pill(text: "In memory", symbol: "bolt.fill", tint: Tokens.Color.ready) }
                }
                Text(model.id).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.tertiaryLabel)
            }
            Spacer()
            InstallLabel(install: console.install(of: model), resident: model.resident)
            if case .notDownloaded = console.install(of: model) {
                Button("Download") { console.download(model: model.id) }
                    .controlSize(.small)
                    .help("Download the weights now without loading the model")
            }
            Button {
                console.selectedModelID = model.id
                console.section = .models
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show its card on the Models page")
            .accessibilityLabel("Show \(model.title) on the Models page")
            Toggle("On", isOn: Binding(get: { model.enabled }, set: { onToggle($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(!pluginEnabled || (model.unavailable != nil && !model.enabled))
                .accessibilityLabel("\(model.title) on")
        }
        .padding(.vertical, Tokens.Space.s)
        .overlay(alignment: .bottom) { Separator(.horizontal) }
        .opacity(pluginEnabled && model.enabled ? 1 : 0.65)
    }
}

// MARK: - Trusted teams

private struct TrustedTeamsCard: View {
    let teams: [EngineTrustedTeam]
    let onRevoke: (EngineTeam) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack {
                Label("Trusted Teams", systemImage: "checkmark.shield").font(Tokens.Font.headline)
                Spacer()
            }
            Text("The engine runs a plugin only when its Developer ID signature is from one of these teams. A repo URL never "
                + "adds a team: a plugin from a new team asks first.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(teams) { trusted in
                    HStack(spacing: Tokens.Space.m) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trusted.team.name).font(Tokens.Font.body)
                            Text(trusted.team.id).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.tertiaryLabel)
                        }
                        Spacer()
                        if trusted.builtIn {
                            Pill(text: "This engine's team", symbol: "lock.fill")
                        } else {
                            if let added = trusted.addedAt {
                                Text("Added \(added.formatted(date: .abbreviated, time: .omitted))")
                                    .font(Tokens.Font.caption)
                                    .foregroundStyle(Tokens.Color.tertiaryLabel)
                            }
                            Button("Remove", role: .destructive) { onRevoke(trusted.team) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.vertical, Tokens.Space.s)
                    .overlay(alignment: .bottom) { Separator(.horizontal) }
                }
            }
        }
        .padding(Tokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

// MARK: - Sheets

/// Asks for a plugin's repo URL and adds it. A plugin from a team that isn't trusted yet turns the sheet into the trust
/// prompt.
private struct AddPluginSheet: View {
    let console: EngineConsoleModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var adding: URL?

    var body: some View {
        if let request = console.trustPrompt {
            TrustPromptSheet(request: request, onTrust: { console.trust(request) }, onDecline: { console.decline(request) })
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack(spacing: Tokens.Space.m) {
                IconTile(symbol: "puzzlepiece.extension", tint: Tokens.Color.accent, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a Plugin").font(Tokens.Font.panelTitle)
                    Text("From its Git repo. The engine installs the newest release that suits it.")
                        .font(Tokens.Font.body)
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                TextField("Repository", text: $text, prompt: Text("https://github.com/owner/plugin"))
                    .textFieldStyle(.roundedBorder)
                    .font(Tokens.Font.mono)
                    .disabled(adding != nil)
                    .onSubmit(add)
                Text("A GitHub repo URL, or owner/repo. Its releases carry the signed plugin; the signature, not the URL, "
                    + "decides whether it runs.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let adding {
                HStack(spacing: Tokens.Space.s) {
                    if let fraction = console.addProgress(adding) ?? nil {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().controlSize(.small)
                        Text("Reading releases, downloading and checking the signature…")
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Tokens.Color.secondaryLabel)
                    }
                }
            }
            if let error {
                Callout(symbol: "exclamationmark.triangle.fill", tint: Tokens.Color.failure, text: error)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(EngineConsoleModel.repositoryURL(text) == nil || adding != nil)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 520)
    }

    private func add() {
        guard let url = EngineConsoleModel.repositoryURL(text), adding == nil else { return }
        error = nil
        adding = url
        Task {
            do {
                try await console.addPlugin(repository: url)
                // A plugin from a new team stays in this sheet to ask about the team.
                if console.trustPrompt == nil { dismiss() }
            } catch {
                self.error = EngineConsoleModel.describe(error)
            }
            adding = nil
        }
    }
}

/// A plugin signed by a team the engine doesn't trust yet: who signed it, and the operator's choice.
private struct TrustPromptSheet: View {
    let request: PluginTrustRequest
    let onTrust: () -> Void
    let onDecline: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack(spacing: Tokens.Space.m) {
                IconTile(symbol: "checkmark.shield", tint: Tokens.Color.working, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trust \(request.team.name)?").font(Tokens.Font.panelTitle)
                    Text("\(request.pluginTitle) \(request.version) is signed by a team this engine doesn't trust yet.")
                        .font(Tokens.Font.body)
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                InfoRow("Team", value: request.team.name)
                InfoRow("Team ID", value: request.team.id)
                if let identity = request.signingIdentity { InfoRow("Signed as", value: identity) }
                InfoRow("Notarized by Apple", value: request.notarized ? "Yes" : "No",
                        color: request.notarized ? nil : Tokens.Color.failure)
                InfoRow("Plugin", value: "\(request.pluginID) \(request.version)")
                InfoRow("Repository", value: request.repository.absoluteString)
                if !request.models.isEmpty { InfoRow("Models", value: request.models.joined(separator: ", ")) }
            }
            if !request.notarized {
                Callout(symbol: "exclamationmark.triangle.fill", tint: Tokens.Color.failure,
                        text: "Apple hasn't notarized this build. Trust it only if you know the team.")
            }
            Text("Trusting the team lets this engine run any plugin it signs, including later updates. You can remove it "
                + "from the trusted teams on this page.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Don't Trust", role: .cancel) {
                    onDecline()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Trust and Install") {
                    onTrust()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Space.xl)
        .frame(width: 540)
    }
}
