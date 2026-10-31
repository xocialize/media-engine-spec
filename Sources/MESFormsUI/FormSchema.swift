import Foundation
import MESCore

/// How one parameter is edited. Resolved from the `x-mes-ui` hint when it fits the schema (Base §6.1), otherwise
/// from the schema's shape, so a descriptor without hints still gets a usable form.
public indirect enum FieldWidget: Equatable, Sendable {
    /// One of `options` (an `enum`).
    case picker([JSONValue])
    /// Any subset of `options` (an array of `enum` items).
    case multiPicker([JSONValue])
    case toggle
    case slider(ClosedRange<Double>, integer: Bool)
    case stepper(ClosedRange<Int>)
    /// An integer seed; empty means the engine picks one.
    case seed
    /// `{width, height}`.
    case size(minimum: Int)
    /// `W:H`.
    case aspect
    /// `#rrggbb`.
    case color
    /// A preset voice's id (Base §6.1, §6.5): a picker filled from the chosen model's voice list.
    case voice
    case text
    case textarea
    case integer(ClosedRange<Int>?)
    case number(ClosedRange<Double>?)
    /// A nested object, edited field by field.
    case object([FormField])
    /// `oneOf`: pick a variant, then edit it.
    case choice([FormVariant])
    /// Anything else, as JSON text.
    case json
}

/// One variant of a `oneOf`.
public struct FormVariant: Equatable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public var schema: JSONValue
    public var fields: [FormField]
}

/// One parameter, ready to render: what to call it, where it goes, and how to edit it.
public struct FormField: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var label: String
    public var help: String?
    public var group: String?
    public var order: Int
    public var advanced: Bool
    public var required: Bool
    public var schema: JSONValue
    public var widget: FieldWidget
    /// The schema's `default`, shown until the person changes it. Unchanged values aren't sent: the engine applies
    /// its own defaults.
    public var defaultValue: JSONValue?
}

public enum FormSchema {
    /// The fields of an object schema (a descriptor's `params`, a nested object, an extension's schema), in display
    /// order: by `group` (ungrouped first), then `order`, then name.
    public static func fields(of schema: JSONValue) -> [FormField] {
        let properties = schema["properties"]?.objectValue ?? [:]
        let requiredOrder = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let required = Set(requiredOrder)
        return properties.map { name, property in
            var f = field(name, property, required: required.contains(name))
            // Without an order hint, required properties keep the order the schema lists them in (left, top, right,
            // bottom), ahead of the rest; JSON objects themselves carry no order.
            if property["x-mes-ui"]?["order"] == nil, let i = requiredOrder.firstIndex(of: name) { f.order = 1000 + i }
            else if property["x-mes-ui"]?["order"] == nil { f.order = 2000 }
            return f
        }
            .sorted { a, b in
                if (a.group ?? "") != (b.group ?? "") { return (a.group ?? "") < (b.group ?? "") }
                if a.order != b.order { return a.order < b.order }
                return a.name < b.name
            }
    }

    static func field(_ name: String, _ schema: JSONValue, required: Bool) -> FormField {
        let hints = schema["x-mes-ui"]
        return FormField(name: name, label: hints?["label"]?.stringValue ?? label(name), help: hints?["help"]?.stringValue,
                         group: hints?["group"]?.stringValue, order: hints?["order"]?.intValue ?? 2000,
                         advanced: hints?["advanced"]?.boolValue ?? false, required: required, schema: schema,
                         widget: widget(name: name, schema: schema, hint: hints?["widget"]?.stringValue),
                         defaultValue: schema["default"])
    }

    /// `negative_prompt` → "Negative prompt".
    public static func label(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == "." }).map(String.init)
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    public static func widget(name: String, schema: JSONValue, hint: String?) -> FieldWidget {
        let type = schema["type"]?.stringValue
        let options = schema["enum"]?.arrayValue
        let minimum = schema["minimum"]?.numberValue
        let maximum = schema["maximum"]?.numberValue
        let bounded = minimum.flatMap { lo in maximum.map { hi in lo...hi } }

        if let variants = schema["oneOf"]?.arrayValue ?? schema["anyOf"]?.arrayValue {
            return .choice(variants.enumerated().map { i, v in
                FormVariant(id: i, title: v["title"]?.stringValue ?? variantTitle(v, index: i), schema: v, fields: fields(of: v))
            })
        }
        if type == "array", let items = schema["items"]?["enum"]?.arrayValue { return .multiPicker(items) }
        if let options { return .picker(options) }

        switch hint {
        case "toggle" where type == "boolean": return .toggle
        case "seed" where type == "integer": return .seed
        case "size" where type == "object": return .size(minimum: sizeMinimum(schema))
        case "aspect" where type == "string": return .aspect
        case "color" where type == "string": return .color
        case "voice" where type == "string": return .voice
        case "textarea" where type == "string": return .textarea
        case "text" where type == "string": return .text
        case "slider" where (type == "number" || type == "integer") && bounded != nil:
            return .slider(bounded!, integer: type == "integer")
        case "stepper" where type == "integer" && bounded != nil:
            return .stepper(Int(bounded!.lowerBound)...Int(min(bounded!.upperBound, Double(Int.max / 2))))
        default: break
        }

        switch type {
        case "boolean": return .toggle
        case "integer":
            if name == "seed" { return .seed }
            if let bounded, bounded.upperBound - bounded.lowerBound <= 100 {
                return .stepper(Int(bounded.lowerBound)...Int(bounded.upperBound))
            }
            return .integer(bounded.map { Int(max($0.lowerBound, Double(Int.min / 2)))...Int(min($0.upperBound, Double(Int.max / 2))) })
        case "number": return bounded.map { .slider($0, integer: false) } ?? .number(nil)
        case "string":
            if name == "voice" { return .voice }
            if let max = schema["maxLength"]?.intValue, max > 200 { return .textarea }
            return .text
        case "object":
            let props = schema["properties"]?.objectValue ?? [:]
            if Set(props.keys) == ["width", "height"] { return .size(minimum: sizeMinimum(schema)) }
            return props.isEmpty ? .json : .object(fields(of: schema))
        default: return .json
        }
    }

    static func sizeMinimum(_ schema: JSONValue) -> Int {
        schema["properties"]?["width"]?["minimum"]?.intValue ?? 1
    }

    /// A variant without a `title`: its required keys, e.g. "Left · Top · Right · Bottom" or "Size · Anchor".
    static func variantTitle(_ v: JSONValue, index: Int) -> String {
        let keys = v["required"]?.arrayValue?.compactMap(\.stringValue)
            ?? v["properties"]?.objectValue?.keys.sorted() ?? []
        return keys.isEmpty ? "Option \(index + 1)" : keys.map(label).joined(separator: " · ")
    }

    /// A value that satisfies `schema` with the least invention: the default, else the first option, else the
    /// minimum, and for objects every required property. Used when a person picks a `oneOf` variant or turns on an
    /// extension.
    public static func initialValue(_ schema: JSONValue) -> JSONValue {
        if let d = schema["default"] { return d }
        if let first = schema["enum"]?.arrayValue?.first { return first }
        if let variants = schema["oneOf"]?.arrayValue, let first = variants.first { return initialValue(first) }
        switch schema["type"]?.stringValue {
        case "boolean": return false
        case "integer", "number": return .number(schema["minimum"]?.numberValue ?? 0)
        case "string": return .string("")
        case "array":
            if let item = schema["items"]?["enum"]?.arrayValue?.first, (schema["minItems"]?.intValue ?? 0) > 0 { return [item] }
            return []
        case "object":
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var object: [String: JSONValue] = [:]
            for (name, property) in schema["properties"]?.objectValue ?? [:]
            where required.contains(name) || property["default"] != nil {
                object[name] = initialValue(property)
            }
            return .object(object)
        default: return .null
        }
    }

    /// Which `oneOf` variant a value matches, by validation.
    public static func variantIndex(of value: JSONValue?, in variants: [FormVariant]) -> Int? {
        guard let value else { return nil }
        let validator = SchemaValidator()
        return variants.first { validator.validate(value, against: $0.schema).isEmpty }?.id
    }

    /// `#rrggbb` ↔ components in 0…1.
    public static func rgb(_ hex: String) -> (Double, Double, Double)? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }

    public static func hex(_ r: Double, _ g: Double, _ b: Double) -> String {
        func byte(_ x: Double) -> Int { Int((min(1, max(0, x)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    /// A short display form of a JSON value (picker labels, readouts).
    public static func display(_ value: JSONValue) -> String {
        switch value {
        case .string(let s):
            // Identifiers read as words (`golden_hour` → "Golden hour"); anything else (`image/png`) as written.
            return s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" } && s.first?.isLetter == true ? label(s) : s
        // Integers to 2^53 − 1 (seeds use the whole range) print without a ".0".
        case .number(let n): return n.rounded() == n && abs(n) <= 9_007_199_254_740_991 ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "On" : "Off"
        case .null: return "—"
        default:
            return (try? String(decoding: MESJSON.encoder.encode(value), as: UTF8.self)) ?? "…"
        }
    }
}
