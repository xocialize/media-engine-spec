import AppKit
import DesignScaffold
import DesignScaffoldControls
import MESCore
import SwiftUI

/// One parameter: its editor, then its problem (from validation) or its help line.
public struct FieldRow: View {
    let field: FormField
    @Binding var value: JSONValue?
    let issue: String?

    public init(field: FormField, value: Binding<JSONValue?>, issue: String? = nil) {
        self.field = field
        _value = value
        self.issue = issue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            FieldEditor(field: field, value: $value)
            if let issue {
                Text(issue).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.failure)
            } else if let help = field.help {
                Text(help).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The control for one widget. Unset values display the schema default (or nothing) and send nothing.
struct FieldEditor: View {
    let field: FormField
    @Binding var value: JSONValue?

    var body: some View {
        switch field.widget {
        case .picker(let options): PickerEditor(field: field, options: options, value: $value)
        case .multiPicker(let options): MultiPickerEditor(field: field, options: options, value: $value)
        case .toggle:
            LabeledContent(field.label) {
                Toggle(field.label, isOn: Binding(get: { (value ?? field.defaultValue)?.boolValue ?? false },
                                                  set: { value = .bool($0) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
        case .slider(let range, let integer):
            if integer {
                LabeledSlider(field.label, value: Binding(get: { (value ?? field.defaultValue)?.intValue ?? Int(range.lowerBound) },
                                                          set: { value = .number(Double($0)) }),
                              in: Int(range.lowerBound)...Int(range.upperBound))
            } else {
                LabeledSlider(field.label, value: Binding(get: { (value ?? field.defaultValue)?.numberValue ?? range.lowerBound },
                                                          set: { value = .number(($0 * 1000).rounded() / 1000) }),
                              in: range, decimals: range.upperBound - range.lowerBound <= 20 ? 2 : 0)
            }
        case .stepper(let range):
            let current = (value ?? field.defaultValue)?.intValue ?? range.lowerBound
            LabeledContent(field.label) {
                HStack(spacing: Tokens.Space.s) {
                    Text("\(current)").font(Tokens.Font.metricInline)
                    Stepper(field.label, value: Binding(get: { current }, set: { value = .number(Double($0)) }), in: range)
                        .labelsHidden()
                }
            }
        case .seed: SeedEditor(field: field, value: $value)
        case .size(let minimum): SizeEditor(field: field, minimum: minimum, value: $value)
        case .aspect: AspectEditor(field: field, value: $value)
        case .color: ColorEditor(field: field, value: $value)
        case .text:
            LabeledContent(field.label) {
                TextField(field.label, text: stringBinding, prompt: field.defaultValue?.stringValue.map { Text($0) })
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
        case .textarea: TextAreaEditor(label: field.label, text: stringBinding)
        case .integer:
            LabeledContent(field.label) {
                TextField(field.label, value: Binding(get: { value?.intValue }, set: { value = $0.map { .number(Double($0)) } }),
                          format: .number.grouping(.never), prompt: field.defaultValue.map { Text(FormSchema.display($0)) })
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 120)
            }
        case .number:
            LabeledContent(field.label) {
                TextField(field.label, value: Binding(get: { value?.numberValue }, set: { value = $0.map { .number($0) } }),
                          format: .number, prompt: field.defaultValue.map { Text(FormSchema.display($0)) })
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 120)
            }
        case .object(let fields): ObjectEditor(label: field.label, fields: fields, value: $value)
        case .choice(let variants): ChoiceEditor(field: field, variants: variants, value: $value)
        case .json: JSONEditor(label: field.label, value: $value)
        }
    }

    /// Empty text clears the value.
    var stringBinding: Binding<String> {
        Binding(get: { value?.stringValue ?? "" }, set: { value = $0.isEmpty ? nil : .string($0) })
    }
}

extension Binding where Value == JSONValue? {
    /// The binding for one property of an object value. Clearing the last property clears the object.
    func child(_ key: String) -> Binding<JSONValue?> {
        Binding(get: { wrappedValue?[key] }, set: { new in
            var object = wrappedValue?.objectValue ?? [:]
            object[key] = new
            wrappedValue = object.isEmpty ? nil : .object(object)
        })
    }
}

// MARK: - Editors

struct PickerEditor: View {
    let field: FormField
    let options: [JSONValue]
    @Binding var value: JSONValue?

    /// Few short options with a default read best as a segmented control; the rest as a menu with an
    /// "engine default" entry, so leaving it unset stays possible.
    var segmented: Bool {
        options.count <= 4 && field.defaultValue != nil && options.allSatisfy { FormSchema.display($0).count <= 10 }
    }

    var body: some View {
        LabeledContent(field.label) {
            Picker(field.label, selection: Binding(get: { selection }, set: { value = $0 < 0 ? nil : options[$0] })) {
                if !segmented && !field.required {
                    Text(field.defaultValue.map { "Default (\(FormSchema.display($0)))" } ?? "Engine default").tag(-1)
                }
                ForEach(options.indices, id: \.self) { i in Text(FormSchema.display(options[i])).tag(i) }
            }
            .labelsHidden()
            .modifier(PickerStyleModifier(segmented: segmented))
            .fixedSize()
        }
    }

    var selection: Int {
        if let value, let i = options.firstIndex(of: value) { return i }
        if segmented, let d = field.defaultValue, let i = options.firstIndex(of: d) { return i }
        return -1
    }
}

struct PickerStyleModifier: ViewModifier {
    let segmented: Bool
    func body(content: Content) -> some View {
        if segmented { content.pickerStyle(.segmented) } else { content.pickerStyle(.menu) }
    }
}

struct MultiPickerEditor: View {
    let field: FormField
    let options: [JSONValue]
    @Binding var value: JSONValue?

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: Tokens.Space.m) {
                ForEach(options.indices, id: \.self) { i in
                    Toggle(FormSchema.display(options[i]), isOn: Binding(get: { chosen.contains(options[i]) }, set: { on in
                        var next = chosen.filter { $0 != options[i] }
                        if on { next.append(options[i]) }
                        let ordered = options.filter(next.contains)
                        value = ordered.isEmpty ? nil : .array(ordered)
                    }))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    var chosen: [JSONValue] { (value ?? field.defaultValue)?.arrayValue ?? [] }
}

struct SeedEditor: View {
    let field: FormField
    @Binding var value: JSONValue?

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: Tokens.Space.xs) {
                TextField(field.label, value: Binding(get: { value?.intValue }, set: { value = $0.map { .number(Double(max(0, $0))) } }),
                          format: .number.grouping(.never), prompt: Text("Random"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 130)
                Button { value = .number(Double(Int.random(in: 0...2_147_483_647))) } label: { Image(systemName: "dice") }
                    .help("Pick a seed")
                if value != nil {
                    Button { value = nil } label: { Image(systemName: Tokens.Symbol.cancel) }
                        .buttonStyle(.borderless).foregroundStyle(Tokens.Color.secondaryLabel)
                        .help("Random each run")
                }
            }
        }
    }
}

struct SizeEditor: View {
    let field: FormField
    let minimum: Int
    @Binding var value: JSONValue?

    static let presets: [(Int, Int)] = [(512, 512), (768, 768), (1024, 1024), (1024, 768), (768, 1024), (1280, 720),
                                        (720, 1280), (1536, 1024), (1024, 1536)]

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: Tokens.Space.xs) {
                dimension("Width", \.width)
                Text("×").foregroundStyle(Tokens.Color.secondaryLabel)
                dimension("Height", \.height)
                Menu {
                    ForEach(Self.presets.filter { $0.0 >= minimum && $0.1 >= minimum }, id: \.0.hashValue) { p in
                        Button("\(p.0) × \(p.1)") { set(p.0, p.1) }
                    }
                    Divider()
                    Button("Engine default") { value = nil }
                } label: { Image(systemName: "rectangle.dashed") }
                    .menuStyle(.borderlessButton).fixedSize().help("Presets")
            }
        }
    }

    struct Dimensions { var width: Int?; var height: Int? }

    var current: Dimensions { Dimensions(width: value?["width"]?.intValue, height: value?["height"]?.intValue) }

    func dimension(_ name: String, _ key: WritableKeyPath<Dimensions, Int?>) -> some View {
        TextField(name, value: Binding(get: { current[keyPath: key] }, set: { new in
            var d = current
            d[keyPath: key] = new
            guard d.width != nil || d.height != nil else { value = nil; return }
            set(d.width ?? d.height!, d.height ?? d.width!)            // both are required: a lone side makes a square
        }), format: .number.grouping(.never), prompt: Text(name == "Width" ? "W" : "H"))
            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 64)
    }

    func set(_ w: Int, _ h: Int) { value = ["width": .number(Double(w)), "height": .number(Double(h))] }
}

struct AspectEditor: View {
    let field: FormField
    @Binding var value: JSONValue?
    static let presets = ["1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16", "21:9"]

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: Tokens.Space.xs) {
                TextField(field.label, text: Binding(get: { value?.stringValue ?? "" }, set: { value = $0.isEmpty ? nil : .string($0) }),
                          prompt: Text("W:H"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 70)
                Menu {
                    ForEach(Self.presets, id: \.self) { p in Button(p) { value = .string(p) } }
                    Divider()
                    Button("Engine default") { value = nil }
                } label: { Image(systemName: "aspectratio") }
                    .menuStyle(.borderlessButton).fixedSize().help("Presets")
            }
        }
    }
}

struct ColorEditor: View {
    let field: FormField
    @Binding var value: JSONValue?

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: Tokens.Space.s) {
                Text(hex).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.secondaryLabel)
                ColorPicker(field.label, selection: Binding(get: { color }, set: { new in
                    guard let c = NSColor(new).usingColorSpace(.sRGB) else { return }
                    value = .string(FormSchema.hex(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)))
                }), supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    var hex: String { (value ?? field.defaultValue)?.stringValue ?? "#000000" }
    var color: Color {
        guard let (r, g, b) = FormSchema.rgb(hex) else { return .black }
        return Color(.sRGB, red: r, green: g, blue: b)
    }
}

struct TextAreaEditor: View {
    let label: String
    @Binding var text: String
    var prompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            Text(label)
            TextEditor(text: $text)
                .font(Tokens.Font.body)
                .scrollContentBackground(.hidden)
                .frame(height: 64)                                  // a fixed height keeps the form's layout deterministic
                .padding(Tokens.Space.xs)
                .background(Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty, let prompt {
                        Text(prompt).foregroundStyle(Tokens.Color.tertiaryLabel)
                            .padding(.horizontal, Tokens.Space.s).padding(.vertical, Tokens.Space.xs).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
                    .strokeBorder(Tokens.Color.separator, lineWidth: Tokens.Layout.hairline))
                .accessibilityLabel(label)
        }
    }
}

struct ObjectEditor: View {
    let label: String
    let fields: [FormField]
    @Binding var value: JSONValue?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            Text(label).font(Tokens.Font.caption.weight(.semibold)).foregroundStyle(Tokens.Color.secondaryLabel)
            VStack(alignment: .leading, spacing: Tokens.Space.s) {
                ForEach(fields) { f in FieldRow(field: f, value: $value.child(f.name)) }
            }
            .padding(.leading, Tokens.Space.m)
        }
    }
}

struct ChoiceEditor: View {
    let field: FormField
    let variants: [FormVariant]
    @Binding var value: JSONValue?
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            LabeledContent(field.label) {
                Picker(field.label, selection: Binding(get: { chosen ?? -1 }, set: { i in
                    chosen = i < 0 ? nil : i
                    value = i < 0 ? nil : FormSchema.initialValue(variants[i].schema)
                })) {
                    if !field.required { Text("Engine default").tag(-1) }
                    ForEach(variants) { v in Text(v.title).tag(v.id) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            if let chosen, variants.indices.contains(chosen) {
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    ForEach(variants[chosen].fields) { f in FieldRow(field: f, value: $value.child(f.name)) }
                }
                .padding(.leading, Tokens.Space.m)
            }
        }
        .onAppear { chosen = FormSchema.variantIndex(of: value, in: variants) }
        .onChange(of: value) { _, new in if new == nil { chosen = nil } }
    }
}

struct JSONEditor: View {
    let label: String
    @Binding var value: JSONValue?
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        LabeledContent(label) {
            TextField(label, text: $text, prompt: Text("JSON"))
                .labelsHidden().textFieldStyle(.roundedBorder).font(Tokens.Font.mono)
                .foregroundStyle(invalid ? Tokens.Color.failure : Tokens.Color.label)
                .onSubmit(commit)
        }
        .onAppear { text = value.map(FormSchema.display) ?? "" }
    }

    func commit() {
        if text.isEmpty { value = nil; invalid = false; return }
        if let parsed = try? MESJSON.decoder.decode(JSONValue.self, from: Data(text.utf8)) { value = parsed; invalid = false }
        else { invalid = true }
    }
}
