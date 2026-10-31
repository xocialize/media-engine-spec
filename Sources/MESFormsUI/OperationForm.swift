import DesignScaffold
import MESCore
import SwiftUI

/// An operation's controls, rendered from its descriptor (MES:DLV-4): text inputs, model offers with their licences,
/// parameters by group with an advanced section, and extensions. Media inputs belong to the host (drag and drop,
/// file panels, earlier results), which supplies a view for each slot.
///
///     OperationForm(form: form) { spec in MyDropWell(spec) }
///
/// Lite and Desktop both use this view, so the paid app has no form the spec can't describe.
public struct OperationForm<MediaSlot: View>: View {
    @Bindable var form: OperationFormModel
    let mediaSlot: (InputSpec) -> MediaSlot

    public init(form: OperationFormModel, @ViewBuilder mediaSlot: @escaping (InputSpec) -> MediaSlot) {
        self.form = form
        self.mediaSlot = mediaSlot
    }

    public var body: some View {
        ScrollView {
            OperationFormContent(form: form, mediaSlot: mediaSlot)
                .padding(Tokens.Space.l)
        }
    }
}

extension OperationForm where MediaSlot == MediaSlotPlaceholder {
    /// With placeholder media slots, for previews and hosts that collect media elsewhere.
    public init(form: OperationFormModel) {
        self.init(form: form) { MediaSlotPlaceholder(spec: $0) }
    }
}

/// The form without its scroll view, for hosts that place it in their own (and for snapshots).
public struct OperationFormContent<MediaSlot: View>: View {
    @Bindable var form: OperationFormModel
    let mediaSlot: (InputSpec) -> MediaSlot

    public init(form: OperationFormModel, @ViewBuilder mediaSlot: @escaping (InputSpec) -> MediaSlot) {
        self.form = form
        self.mediaSlot = mediaSlot
    }

    public var body: some View {
        let issues = form.issues
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            header
            if !form.descriptor.inputs.isEmpty {
                section("Inputs") {
                    ForEach(form.textInputs, id: \.name) { spec in
                        TextAreaEditor(label: FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"),
                                       text: Binding(get: { form.text[spec.name] ?? "" }, set: { form.text[spec.name] = $0 }),
                                       prompt: spec.notes)
                    }
                    ForEach(form.mediaInputs, id: \.name) { spec in mediaSlot(spec) }
                }
            }
            if !form.descriptor.models.isEmpty {
                section("Model") { ModelSection(form: form) }
            }
            ForEach(OperationFormModel.grouped(form.mainFields), id: \.group) { group in
                section(group.group ?? "Parameters") { rows(group.fields, issues: issues) }
            }
            if !form.advancedFields.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    Button {
                        form.showsAdvanced.toggle()
                    } label: {
                        SectionHeader("Advanced") {
                            Image(systemName: form.showsAdvanced ? "chevron.down" : "chevron.right")
                                .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(form.showsAdvanced ? "Hide advanced parameters" : "Show advanced parameters")
                    if form.showsAdvanced {
                        card { rows(form.advancedFields, issues: issues) }
                    }
                }
            }
            if let extensions = form.descriptor.extensions, !extensions.isEmpty {
                section("Extensions") {
                    ForEach(extensions, id: \.name) { ext in ExtensionRow(form: form, ext: ext, issue: issues[ext.name]) }
                }
            }
        }
        .controlSize(.small)
        .font(Tokens.Font.body)
        .environment(\.voiceChoices, form.voiceChoices)
        // The `voice` widget's list follows the chosen model (Base §6.5).
        .task(id: form.effectiveModel?.id) { await form.loadVoices() }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(form.descriptor.title).font(Tokens.Font.panelTitle)
                Spacer()
                Button("Reset") { form.reset() }
                    .disabled(form.values.isEmpty && form.model == nil && form.extensions.isEmpty && !form.stream)
            }
            Text(form.descriptor.operation).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel)
            if let summary = form.descriptor.summary {
                Text(summary).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func rows(_ fields: [FormField], issues: [String: String]) -> some View {
        ForEach(fields) { field in
            FieldRow(field: field, value: Binding(get: { form.value(at: [field.name]) }, set: { form.setValue($0, at: [field.name]) }),
                     issue: issues[field.name])
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            SectionHeader(title)
            card(content: content)
        }
    }

    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.m) { content() }
            .padding(Tokens.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

extension OperationFormContent where MediaSlot == MediaSlotPlaceholder {
    public init(form: OperationFormModel) {
        self.init(form: form) { MediaSlotPlaceholder(spec: $0) }
    }
}

/// A media input's slot when the host supplies none: what it takes, and whether it's required.
public struct MediaSlotPlaceholder: View {
    let spec: InputSpec
    public init(spec: InputSpec) { self.spec = spec }

    public var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Image(systemName: spec.kind == .mask ? "circle.lefthalf.filled" : spec.kind == .data ? "curlybraces"
                : spec.kind == .audio ? "waveform" : "photo")
                .foregroundStyle(Tokens.Color.secondaryLabel)
            VStack(alignment: .leading, spacing: 2) {
                Text(FormSchema.label(spec.name))
                Text(detail).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            Spacer()
        }
        .padding(Tokens.Space.s)
        .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .strokeBorder(Tokens.Color.separator, style: StrokeStyle(lineWidth: Tokens.Layout.hairline, dash: [4, 3])))
    }

    var detail: String {
        var parts = [spec.kind.rawValue, spec.required ? "required" : "optional"]
        if let max = spec.max, max > 1 { parts.append("up to \(max)") }
        return parts.joined(separator: " · ")
    }
}

/// Every model offer with its licence (Base §10.2), and the policy toggles (Lite LITE-9, LITE-10).
struct ModelSection: View {
    @Bindable var form: OperationFormModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            ModelRow(title: "Automatic", detail: form.effectiveModel.map { "Engine's choice: \($0.title)" } ?? "Engine's choice",
                     offer: nil, selected: form.model == nil, excluded: false) { form.model = nil }
            ForEach(form.descriptor.models, id: \.id) { offer in
                ModelRow(title: offer.title, detail: ModelRow.detail(offer), offer: offer, selected: form.model == offer.id,
                         excluded: form.isExcluded(offer)) { form.model = offer.id }
            }
            Toggle("Commercial-use models only", isOn: Binding(get: { form.policy.license == .commercialUse },
                                                               set: { form.policy.license = $0 ? .commercialUse : nil }))
                .toggleStyle(.checkbox).padding(.top, Tokens.Space.xs)
            if !form.streamableOutputs.isEmpty, form.descriptor.models.contains(where: \.streams) {
                Toggle("Stream as it's made", isOn: $form.stream)
                    .toggleStyle(.checkbox)
                    .disabled(!form.canStream)
                    .help(form.canStream ? "Chunks arrive while the job runs; with no model chosen, the engine picks one that streams."
                        : "\(form.effectiveModel?.title ?? "This model") doesn't stream.")
            }
            if form.descriptor.remote?.possible == true {
                Toggle("Allow remote providers (may bill)", isOn: Binding(get: { form.policy.remote == .allow },
                                                                          set: { form.policy.remote = $0 ? .allow : nil }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

struct ModelRow: View {
    let title: String
    let detail: String
    let offer: ModelOffer?
    let selected: Bool
    let excluded: Bool
    let choose: () -> Void

    // Not a Button: the licence line carries its own link to the terms, and a link inside a button fights it.
    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Tokens.Color.accent : Tokens.Color.secondaryLabel)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Tokens.Space.s) {
                    Text(title).lineLimit(1)
                    if offer?.isDefault == true {
                        Text("default").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                    } else if offer?.namedOnly == true {
                        Text("only when chosen").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
                            .help("The engine never picks this model on its own; it runs only when you choose it.")
                    }
                }
                if let offer { LicenseLine(license: offer.license) }
                Text(excluded ? "Excluded by the commercial-use policy" : detail)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(excluded ? Tokens.Color.degraded : Tokens.Color.secondaryLabel)
                    .help(offer?.notes ?? "")                     // the model's usage guidance (Base §6 rule 5)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.xs)
        .background(selected ? Tokens.Color.selectionWash : .clear, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .opacity(excluded ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, choose)                    // VoiceOver and AXPress choose it
    }

    static func detail(_ offer: ModelOffer) -> String {
        var parts: [String] = []
        if let m = offer.memoryClass { parts.append("\(m.rawValue) memory") }
        if let s = offer.speedClass { parts.append(s.rawValue) }
        parts.append(offer.qualityTiers.map(\.rawValue).joined(separator: "/"))
        if let r = offer.remoteProvider { parts.append("remote: \(r.name)\(r.billed ? ", billed" : "")") }
        return parts.joined(separator: " · ")
    }
}

/// A licence in one line: its SPDX id, whether commercial use is allowed, and its terms.
public struct LicenseLine: View {
    let license: License
    public init(license: License) { self.license = license }

    public var body: some View {
        HStack(spacing: Tokens.Space.xs) {
            Text(license.spdx).font(Tokens.Font.mono)
            Circle().fill(color).frame(width: 6, height: 6)
            Text(commercial).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            if let url = license.termsURL.flatMap(URL.init(string:)) {
                Link("Terms", destination: url).font(Tokens.Font.caption).buttonStyle(.link)
            }
        }
        .help(license.notice ?? "")
        .accessibilityElement(children: .combine)
    }

    var commercial: String {
        switch license.commercialUse {
        case .yes: "commercial use allowed"
        case .no: "no commercial use"
        case .unknown: "commercial use unknown"
        }
    }

    var color: Color {
        switch license.commercialUse {
        case .yes: Tokens.Color.ready
        case .no: Tokens.Color.failure
        case .unknown: Tokens.Color.degraded
        }
    }
}

/// An extension: off by default; on, its own fields (Base §6.2).
struct ExtensionRow: View {
    @Bindable var form: OperationFormModel
    let ext: ExtensionSpec
    let issue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Toggle(isOn: Binding(get: { form.isEnabled(ext) }, set: { form.setEnabled(ext, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ext.title)
                    Text(ext.name).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            .toggleStyle(.checkbox)
            if form.isEnabled(ext) {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(FormSchema.fields(of: ext.schema)) { field in
                        FieldRow(field: field, value: Binding(get: { form.extensionValue(ext, at: [field.name]) },
                                                              set: { form.setExtensionValue(ext, $0, at: [field.name]) }))
                    }
                    if let issue { Text(issue).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure) }
                }
                .padding(.leading, Tokens.Space.l)
            }
        }
    }
}
