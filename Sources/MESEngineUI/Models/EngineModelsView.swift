import AppKit
import DesignScaffold
import MESCore
import SwiftUI

/// The Models section: the engine's enabled set. The engine picks a model for each request itself, by operation and
/// quality tier, so the operator doesn't load models here. They choose which ones may be picked: a card per model with
/// its switch, and the detail of how to use the selected one.
struct EngineModelsView: View {
    @Bindable var console: EngineConsoleModel
    @State private var search = ""
    @State private var filter: ModelFilter = .all
    @State private var operation: String?
    @State private var pending: PendingToggle?
    @State private var showsRoutes = true

    var body: some View {
        VStack(spacing: 0) {
            ConsoleSectionHeader(title: "Models",
                                 subtitle: "The engine picks a model for each request from the ones that are on.") {
                Text("\(console.enabledCount) of \(console.models.count) on")
                    .font(Tokens.Font.caption.weight(.semibold))
                    .foregroundStyle(Tokens.Color.secondaryLabel)
                Button {
                    Task { await console.refreshModels() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the models' state again")
            }
            Separator(.horizontal)
            toolbar
            Separator(.horizontal)
            HStack(spacing: 0) {
                list.frame(minWidth: 440)
                if let model = selected {
                    Separator(.vertical)
                    ModelDetailView(console: console, model: model, onToggle: { request(model, enabled: $0) },
                                    onClose: { console.selectedModelID = nil })
                        .frame(minWidth: Tokens.Layout.inspectorWidth, idealWidth: Tokens.Layout.inspectorMaxWidth,
                               maxWidth: Tokens.Layout.inspectorMaxWidth)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .alert(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { pending in
            Button(pending.confirmTitle, role: pending.enabling ? nil : .destructive) {
                console.setEnabled(pending.enabling, model: pending.model.id)
            }
            if pending.enabling, let terms = pending.model.license.termsURL.flatMap(URL.init(string:)) {
                Button("View Terms") { NSWorkspace.shared.open(terms) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
        .alert("Something went wrong", isPresented: Binding(get: { console.actionError != nil },
                                                            set: { if !$0 { console.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(console.actionError ?? "")
        }
    }

    private var selected: EngineModel? {
        console.selectedModelID.flatMap { id in console.models.first { $0.id == id } }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: Tokens.Space.m) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Tokens.Color.tertiaryLabel)
                TextField("Search models", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, Tokens.Space.s)
            .frame(height: Tokens.Layout.controlHeight + 4)
            .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .frame(minWidth: 180, maxWidth: 320)
            Picker("Show", selection: $filter) {
                ForEach(ModelFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Operation", selection: $operation) {
                Text("All operations").tag(String?.none)
                ForEach(console.operationsServed, id: \.self) { op in
                    Text(console.operationTitle(op)).tag(String?.some(op))
                }
            }
            .fixedSize()
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.xl)
        .padding(.vertical, Tokens.Space.s)
    }

    // MARK: - List

    private var visible: [EngineModel] {
        console.models.filter { model in
            filter.admits(model)
                && (operation.map { op in model.roles.contains { $0.operation == op } } ?? true)
                && (search.isEmpty || model.title.localizedCaseInsensitiveContains(search)
                    || model.id.localizedCaseInsensitiveContains(search) || model.summary.localizedCaseInsensitiveContains(search))
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Space.s) {
                if !console.autoswitch.isEmpty {
                    AutoswitchCard(console: console, expanded: $showsRoutes)
                        .padding(.bottom, Tokens.Space.s)
                }
                if console.models.isEmpty {
                    ConsoleEmptyState(symbol: "shippingbox", title: "Reading the engine's models…",
                                      message: "The list appears once the engine has registered its catalog.")
                } else if visible.isEmpty {
                    ConsoleEmptyState(symbol: "magnifyingglass", title: "No models match",
                                      message: "Try another search or filter.")
                } else {
                    let groups = ModelGroup.group(visible)
                    ForEach(groups) { group in
                        HStack(spacing: 6) {
                            Image(systemName: group.symbol)
                            Text(group.title)
                            Text("\(group.models.count)").foregroundStyle(Tokens.Color.tertiaryLabel)
                        }
                        .font(Tokens.Font.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                        .padding(.top, Tokens.Space.s)
                        ForEach(group.models) { model in
                            ModelCard(console: console, model: model, selected: model.id == console.selectedModelID,
                                      onToggle: { request(model, enabled: $0) })
                                .onTapGesture {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        console.selectedModelID = console.selectedModelID == model.id ? nil : model.id
                                    }
                                }
                        }
                    }
                }
            }
            .padding(Tokens.Space.l)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }

    /// Asks before a switch that needs it: accepting an opt-in model's terms, or leaving an operation with no model.
    private func request(_ model: EngineModel, enabled: Bool) {
        if enabled, model.optIn {
            pending = PendingToggle(model: model, enabling: true,
                                    title: "Accept \(model.title)'s licence?",
                                    message: [model.license.notice ?? "\(model.title) is licensed \(model.license.spdx).",
                                              "Turning it on means you accept its terms. Requests run it only when they name it: "
                                                  + "the engine never picks it by itself."].joined(separator: "\n\n"),
                                    confirmTitle: "Accept and Turn On")
        } else if !enabled, case let orphans = console.orphans(ifDisabling: model), !orphans.isEmpty {
            pending = PendingToggle(model: model, enabling: false, title: "Turn off \(model.title)?",
                                    message: "Nothing else that's on serves \(orphans.joined(separator: "; ")). "
                                        + "Clients won't be offered it until you turn a model on for it.",
                                    confirmTitle: "Turn Off")
        } else {
            console.setEnabled(enabled, model: model.id)
        }
    }
}

private struct PendingToggle: Identifiable {
    let model: EngineModel
    let enabling: Bool
    let title: String
    let message: String
    let confirmTitle: String
    var id: String { model.id }
}

private enum ModelFilter: String, CaseIterable, Identifiable {
    case all, on, off, inMemory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .on: "On"
        case .off: "Off"
        case .inMemory: "In Memory"
        }
    }

    func admits(_ model: EngineModel) -> Bool {
        switch self {
        case .all: true
        case .on: model.enabled
        case .off: !model.enabled
        case .inMemory: model.resident
        }
    }
}

/// Models grouped by what they're for: picked automatically, opt-in, or not usable here.
private struct ModelGroup: Identifiable {
    let title: String
    let symbol: String
    let models: [EngineModel]
    var id: String { title }

    static func group(_ models: [EngineModel]) -> [ModelGroup] {
        let unavailable = models.filter { $0.unavailable != nil }
        let usable = models.filter { $0.unavailable == nil }
        return [
            ModelGroup(title: "Available to autoswitch", symbol: "arrow.triangle.branch",
                       models: usable.filter { !$0.optIn && !$0.isNamedOnly }),
            ModelGroup(title: "By name only", symbol: "at", models: usable.filter { !$0.optIn && $0.isNamedOnly }),
            ModelGroup(title: "Opt-in licences", symbol: "checkmark.seal", models: usable.filter(\.optIn)),
            ModelGroup(title: "Not available on this Mac", symbol: "exclamationmark.triangle", models: unavailable),
        ].filter { !$0.models.isEmpty }
    }
}

extension EngineConsoleModel {
    /// Every operation some model serves, in the engine's order.
    var operationsServed: [String] {
        var seen: [String] = []
        for op in operations.map(\.operation) + models.flatMap({ $0.roles.map(\.operation) }) where !seen.contains(op) {
            seen.append(op)
        }
        return seen
    }
}

// MARK: - Autoswitch

/// What a request that names no model gets, per operation and tier, with the models that are on now.
private struct AutoswitchCard: View {
    let console: EngineConsoleModel
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack {
                    Label("Autoswitch", systemImage: "arrow.triangle.branch").font(Tokens.Font.headline)
                    Text("What a request that names no model gets").font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.secondaryLabel)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Tokens.Color.tertiaryLabel)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: Tokens.Space.l, verticalSpacing: Tokens.Space.s) {
                    GridRow {
                        Text("Operation")
                        ForEach(QualityTier.allCases, id: \.self) { Text($0.rawValue.capitalized) }
                    }
                    .font(Tokens.Font.caption.weight(.semibold))
                    .foregroundStyle(Tokens.Color.secondaryLabel)
                    ForEach(console.autoswitch) { route in
                        GridRow {
                            Label(route.title, systemImage: OperationSymbol.symbol(route.operation))
                                .font(Tokens.Font.body.weight(.medium))
                            ForEach(QualityTier.allCases, id: \.self) { tier in
                                pickCell(route.picks.first { $0.tier == tier })
                            }
                        }
                        .font(Tokens.Font.body)
                    }
                }
                Text("Some operations refine the pick per request, e.g. restore chooses by kind. Opt-in models run only when named.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.tertiaryLabel)
            }
        }
        .padding(Tokens.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    @ViewBuilder private func pickCell(_ pick: (tier: QualityTier, model: ModelOffer?)?) -> some View {
        if let pick, let model = pick.model {
            Button { console.selectedModelID = model.id } label: {
                Text(model.title).lineLimit(1).truncationMode(.tail)
            }
            .buttonStyle(.link)
            .help("Show \(model.title)")
        } else if pick != nil {
            Text("No model on").foregroundStyle(Tokens.Color.failure)
        } else {
            Text(missingValue).foregroundStyle(Tokens.Color.tertiaryLabel)
        }
    }
}

// MARK: - Card

private struct ModelCard: View {
    let console: EngineConsoleModel
    let model: EngineModel
    let selected: Bool
    let onToggle: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.m) {
            IconTile(symbol: OperationSymbol.symbol(model.roles.first?.operation), tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 5) {
                FlowRow(spacing: 6) {
                    Text(model.title).font(Tokens.Font.headline).lineLimit(1)
                    ForEach(badges, id: \.text) { Pill(text: $0.text, symbol: $0.symbol, tint: $0.tint) }
                }
                Text(model.id).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel).textSelection(.enabled)
                if !model.summary.isEmpty {
                    Text(model.summary).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(2)
                }
                FlowRow(spacing: 5) {
                    ForEach(model.roles) { role in
                        Pill(text: console.operationTitle(role.operation), symbol: OperationSymbol.symbol(role.operation))
                    }
                    if let bytes = model.footprintBytes { Pill(text: ConsoleFormat.memory(bytes), symbol: "memorychip") }
                    if let speed = model.speedClass { Pill(text: speed.rawValue.capitalized, symbol: "speedometer") }
                    ForEach(model.tags, id: \.self) { Pill(text: $0) }
                }
            }
            Spacer(minLength: Tokens.Space.m)
            VStack(alignment: .trailing, spacing: Tokens.Space.s) {
                Toggle("On", isOn: Binding(get: { model.enabled }, set: onToggle))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.unavailable != nil && !model.enabled)
                    .help(model.enabled ? "Turn off: the engine stops offering it" : "Turn on: the engine may use it")
                InstallLabel(install: console.install(of: model), resident: model.resident)
            }
        }
        .padding(Tokens.Space.m + 2)
        .background(selected ? Tokens.Color.selectionWash : hovered ? Tokens.Color.fillElevated : Tokens.Color.surface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.container))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.container)
                .strokeBorder(selected ? Tokens.Color.accent : Tokens.Color.separator, lineWidth: selected ? 1.5 : 1)
        }
        .opacity(model.enabled || selected ? 1 : 0.62)
        .contentShape(.rect)
        .onHover { hovered = $0 }
        .contextMenu { ModelActions(console: console, model: model) }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color { model.optIn ? Tokens.Color.working : model.enabled ? Tokens.Color.accent : Tokens.Color.secondaryLabel }

    private var badges: [(text: String, symbol: String?, tint: Color)] {
        var out: [(String, String?, Color)] = []
        if model.roles.contains(where: \.isDefault) && model.enabled { out.append(("Default", "star.fill", Tokens.Color.accent)) }
        if model.optIn { out.append(("Opt-in", "checkmark.seal", Tokens.Color.working)) }
        if model.resident { out.append(("In memory", "bolt.fill", Tokens.Color.ready)) }
        if model.unavailable != nil { out.append(("Unavailable", "exclamationmark.triangle.fill", Tokens.Color.failure)) }
        return out
    }
}

/// Download state and memory, under a card's switch.
struct InstallLabel: View {
    let install: EngineModel.Install
    let resident: Bool

    var body: some View {
        switch install {
        case .downloading(let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 70)
                    Text(ConsoleFormat.percent(fraction)).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("Downloading")
                }
            }
            .font(Tokens.Font.caption)
            .foregroundStyle(Tokens.Color.secondaryLabel)
        case .notDownloaded(let bytes):
            Label(bytes.map { "Not downloaded · \(ConsoleFormat.bytes($0))" } ?? "Not downloaded", systemImage: "icloud.and.arrow.down")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.tertiaryLabel)
        case .downloaded(let bytes):
            Label(bytes.map { "On disk · \(ConsoleFormat.bytes($0))" } ?? "On disk", systemImage: "checkmark.circle")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.secondaryLabel)
        case .builtIn:
            Label("Built in", systemImage: "checkmark.circle")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.secondaryLabel)
        }
    }
}

/// A card's actions, in its context menu and the detail panel's menu.
struct ModelActions: View {
    let console: EngineConsoleModel
    let model: EngineModel

    var body: some View {
        if case .notDownloaded = console.install(of: model) {
            Button("Download Now", systemImage: "arrow.down.circle") { console.download(model: model.id) }
        }
        if model.resident {
            Button("Release from Memory", systemImage: "eject") { console.unload(model: model.id) }
        }
        Button("Copy Model ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.id, forType: .string)
        }
        if let url = model.sourceURL {
            Button("Open Model Page", systemImage: "safari") { NSWorkspace.shared.open(url) }
        }
    }
}

/// A symbol for each operation, by the last part of its name.
enum OperationSymbol {
    static func symbol(_ operation: String?) -> String {
        switch operation?.split(separator: ".").last {
        case "generate": "sparkles"
        case "edit": "wand.and.stars"
        case "fill": "paintbrush.pointed"
        case "erase": "eraser"
        case "extend": "arrow.up.left.and.arrow.down.right"
        case "upscale": "arrow.up.forward.square"
        case "restore": "bandage"
        case "relight": "lightbulb"
        case "colorize": "paintpalette"
        case "matte": "person.crop.rectangle"
        case "segment": "square.dashed"
        case "describe": "text.bubble"
        case "score": "star.leadinghalf.filled"
        case "speak", "tts": "waveform"
        case "transcribe": "text.quote"
        case "interpolate": "film.stack"
        default: "shippingbox"
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
