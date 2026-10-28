import AppKit
import DesignScaffold
import MESCore
import SwiftUI

/// The selected model's card in full: what it does, when the engine picks it, how to ask for it by name, how to prompt
/// it, its licence, and its state on this Mac.
struct ModelDetailView: View {
    let console: EngineConsoleModel
    let model: EngineModel
    let onToggle: (Bool) -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Space.l) {
                header
                switchRow
                if let unavailable = model.unavailable {
                    Callout(symbol: "exclamationmark.triangle.fill", tint: Tokens.Color.failure, text: unavailable)
                }
                if !model.summary.isEmpty {
                    Text(model.summary).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true)
                }
                whatItDoes
                usage
                licence
                if model.plugin != nil || model.version != nil { provenance }
                onThisMac
            }
            .padding(Tokens.Space.l)
        }
        .background(Tokens.Color.surfaceElevated)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            IconTile(symbol: OperationSymbol.symbol(model.roles.first?.operation), tint: Tokens.Color.accent, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(Tokens.Font.panelTitle)
                Text(model.id).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel).textSelection(.enabled)
            }
            Spacer()
            Menu {
                ModelActions(console: console, model: model)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close")
        }
    }

    private var switchRow: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.enabled ? "On" : "Off").font(Tokens.Font.headline)
                Text(switchExplanation).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("On", isOn: Binding(get: { model.enabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.unavailable != nil && !model.enabled)
        }
        .padding(Tokens.Space.m)
        .cardSurface()
    }

    private var switchExplanation: String {
        switch (model.enabled, model.optIn) {
        case (true, true):
            "Offered by name only. " + (model.acceptedAt.map { "You accepted its terms \($0.formatted(date: .abbreviated, time: .omitted))." } ?? "")
        case (true, false):
            model.isNamedOnly ? "Offered; runs when a request names it." : "The engine may pick it, and clients may name it."
        case (false, true):
            "Opt-in licence. Turning it on accepts its terms; it then runs only when a request names it."
        case (false, false):
            "Not offered: the engine never picks it and requests can't name it."
        }
    }

    private var whatItDoes: some View {
        DetailSection(title: "What it does") {
            if model.roles.isEmpty {
                Text("It serves no operation of this engine.").foregroundStyle(Tokens.Color.secondaryLabel)
            }
            ForEach(model.roles) { role in
                HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
                    Label(console.operationTitle(role.operation), systemImage: OperationSymbol.symbol(role.operation))
                        .frame(minWidth: 110, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(role.qualityTiers, id: \.self) { Pill(text: $0.rawValue) }
                    }
                    Spacer()
                    Text(roleNote(role)).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                        .multilineTextAlignment(.trailing)
                }
                .font(Tokens.Font.body)
            }
            let picks = console.picks(of: model.id)
            if !picks.isEmpty {
                Text("Picked now for " + picks.map { "\($0.operation) (\($0.tiers.map(\.rawValue).joined(separator: ", ")))" }
                    .joined(separator: "; ") + ".")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
    }

    private func roleNote(_ role: EngineModel.Role) -> String {
        if role.namedOnly { return "By name" }
        if role.isDefault { return model.enabled ? "Default" : "Default when on" }
        return "Alternative"
    }

    private var usage: some View {
        DetailSection(title: "How to use it") {
            if let notes = model.notes, !notes.isEmpty {
                Callout(symbol: "lightbulb", tint: Tokens.Color.working, text: notes)
            }
            if model.roles.contains(where: { $0.isDefault && !$0.namedOnly }) && model.enabled {
                Text("Requests that name no model get it automatically at the tiers above. To ask for it anyway, name it:")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            } else {
                Text("Name it in a request to use it:").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            if let role = model.roles.first {
                CodeBlock(label: "mes CLI", code: cliExample(role))
                CodeBlock(label: "Request JSON", code: jsonExample(role))
                CodeBlock(label: "MCP tool argument", code: "\"model\": \"\(model.id)\"  // \(role.operation.replacingOccurrences(of: ".", with: "_"))")
            }
            if !model.enabled {
                Text("It must be on first.").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.working)
            }
        }
    }

    private func cliExample(_ role: EngineModel.Role) -> String {
        let input = role.operation.hasSuffix("generate") ? "-i prompt=\"a lighthouse at dusk\"" : "-i image=photo.png"
        let tier = role.qualityTiers.contains(.standard) ? "" : role.qualityTiers.first.map { " -p quality=\($0.rawValue)" } ?? ""
        return "mes run \(role.operation) \(input)\(tier) --model \(model.id)"
    }

    private func jsonExample(_ role: EngineModel.Role) -> String {
        let input = role.operation.hasSuffix("generate") ? "\"prompt\": \"a lighthouse at dusk\"" : "\"image\": {\"upload\": \"upl_…\"}"
        return """
        {
          "operation": "\(role.operation)",
          "model": "\(model.id)",
          "inputs": { \(input) }
        }
        """
    }

    private var licence: some View {
        DetailSection(title: "Licence") {
            InfoRow("Licence", value: model.license.spdx)
            InfoRow("Commercial use", value: commercialUse)
            if let accepted = model.acceptedAt {
                InfoRow("Terms accepted", value: accepted.formatted(date: .abbreviated, time: .shortened))
            }
            if let notice = model.license.notice {
                Callout(symbol: "exclamationmark.shield", tint: model.optIn ? Tokens.Color.working : Tokens.Color.secondaryLabel,
                        text: notice)
            }
            if let terms = model.license.termsURL.flatMap(URL.init(string:)) {
                Link(destination: terms) { Label("Read the terms", systemImage: "arrow.up.right.square") }
                    .font(Tokens.Font.body)
            }
        }
    }

    private var commercialUse: String {
        switch model.license.commercialUse {
        case .yes: "Yes"
        case .no: "No"
        case .unknown: "Unknown"
        }
    }

    private var provenance: some View {
        DetailSection(title: "Version") {
            if let plugin = model.plugin {
                HStack {
                    Text("Plugin").foregroundStyle(Tokens.Color.secondaryLabel)
                    Spacer()
                    if console.hasPlugins {
                        Button(plugin.title) {
                            console.selectedPluginID = plugin.id
                            console.section = .plugins
                        }
                        .buttonStyle(.link)
                        .help("Show it on the Plugins page")
                    } else {
                        Text(plugin.title)
                    }
                }
                .font(Tokens.Font.body)
                .padding(.vertical, Tokens.Space.s)
            }
            InfoRow("Installed", value: model.version ?? missingValue)
            if let update = model.update {
                Callout(symbol: "arrow.down.circle.fill", tint: Tokens.Color.accent,
                        text: "Version \(update.version) is available"
                            + (model.plugin.map { " in an update to \($0.title), on the Plugins page." } ?? ".")
                            + (update.notes.map { "\n\n" + $0 } ?? ""))
            }
        }
    }

    private var onThisMac: some View {
        DetailSection(title: "On this Mac") {
            HStack {
                InstallLabel(install: console.install(of: model), resident: model.resident)
                Spacer()
                if case .notDownloaded = console.install(of: model) {
                    Button("Download Now") { console.download(model: model.id) }
                        .help("Download the weights now without loading the model: it loads when a job needs it")
                }
                if model.resident {
                    Button("Release from Memory") { console.unload(model: model.id) }
                }
            }
            if case .notDownloaded = console.install(of: model) {
                Text("Downloading doesn't load it: it stays out of memory until a job needs it.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.secondaryLabel)
            }
            InfoRow("In memory", value: model.resident ? "Yes" : "No")
            InfoRow("Memory when loaded", value: ConsoleFormat.memory(model.footprintBytes))
            if let memoryClass = model.memoryClass { InfoRow("Memory class", value: memoryClass.rawValue.capitalized) }
            if let speed = model.speedClass { InfoRow("Speed", value: speed.rawValue.capitalized) }
            if let source = model.source {
                HStack {
                    Text("Weights").foregroundStyle(Tokens.Color.secondaryLabel)
                    Spacer()
                    if let url = model.sourceURL {
                        Link(source, destination: url).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(source).textSelection(.enabled)
                    }
                }
                .font(Tokens.Font.body)
                .padding(.vertical, Tokens.Space.s)
            }
        }
    }
}

// MARK: - Parts

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            SectionHeader(title)
            content
        }
    }
}

/// A tinted note: a model's prompting advice, a licence notice, why it can't run.
struct Callout: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(Tokens.Font.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(Tokens.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: Tokens.Radius.control + 2))
    }
}

/// Monospaced text with a copy button.
struct CodeBlock: View {
    let label: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(Tokens.Font.caption.weight(.semibold)).foregroundStyle(Tokens.Color.secondaryLabel)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(Tokens.Font.caption)
                }
                .buttonStyle(.borderless)
            }
            Text(code)
                .font(Tokens.Font.mono)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.s)
                .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        }
    }
}
