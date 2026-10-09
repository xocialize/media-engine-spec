import Foundation

/// A JSON Schema (draft 2020-12) validator for the subset MES uses, matching tools/validate.py:
/// type enum const properties required additionalProperties propertyNames minProperties items minItems maxItems
/// minimum maximum exclusiveMinimum minLength maxLength pattern oneOf anyOf allOf if then $ref.
/// Annotations ($schema title description default $defs, x-*) are ignored; any other keyword is reported, so a
/// typo can't silently weaken a schema.
///
/// Engines use it for descriptor `params` (self-contained schemas). Tests and the conformance suite use it with
/// `SchemaLoader` to resolve cross-file `$ref`s in schemas/v0.
public struct SchemaValidator: Sendable {
    public struct Issue: Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var message: String
        public var description: String { "\(path): \(message)" }
    }

    static let assertions: Set<String> = ["type", "enum", "const", "properties", "required", "additionalProperties",
        "propertyNames", "minProperties", "items", "minItems", "maxItems", "minimum", "maximum", "exclusiveMinimum",
        "minLength", "maxLength", "pattern", "oneOf", "anyOf", "allOf", "if", "then", "$ref"]
    static let annotations: Set<String> = ["$schema", "title", "description", "default", "$defs", "$comment"]

    let loader: SchemaLoader?

    public init(loader: SchemaLoader? = nil) { self.loader = loader }

    /// Validates `value` against `schema`. When `schema` is a part of a larger document (e.g. `#/$defs/X`), pass
    /// the whole `document` so local `$ref`s resolve; `base` names the document's file, for cross-file `$ref`s.
    public func validate(_ value: JSONValue, against schema: JSONValue, in document: JSONValue? = nil,
                         base: URL? = nil) -> [Issue] {
        check(value, schema, base: base, root: document ?? schema, path: "$")
    }

    private func check(_ value: JSONValue, _ schema: JSONValue, base: URL?, root: JSONValue, path: String) -> [Issue] {
        if case .bool(let b) = schema { return b ? [] : [Issue(path: path, message: "not allowed")] }
        guard case .object(let s) = schema else { return [Issue(path: path, message: "schema is not an object")] }
        if s.isEmpty { return [] }
        let unknown = s.keys.filter { !Self.assertions.contains($0) && !Self.annotations.contains($0) && !$0.hasPrefix("x-") }
        if !unknown.isEmpty { return [Issue(path: path, message: "unsupported schema keywords \(unknown.sorted())")] }

        var issues: [Issue] = []
        if case .string(let ref)? = s["$ref"] {
            switch resolve(ref, base: base, root: root) {
            case .resolved(let target, let tbase, let troot):
                issues += check(value, target, base: tbase, root: troot, path: path)
            case .failed(let message):
                issues.append(Issue(path: path, message: message))
            }
        }
        if let t = s["type"], !Self.typeMatches(value, t) {
            return issues + [Issue(path: path, message: "expected \(Self.describe(t))")]
        }
        if case .array(let options)? = s["enum"], !options.contains(where: { Self.same($0, value) }) {
            issues.append(Issue(path: path, message: "not one of the allowed values"))
        }
        if let c = s["const"], !Self.same(c, value) { issues.append(Issue(path: path, message: "must equal \(c)")) }

        if case .string(let str) = value {
            if let n = s["minLength"]?.intValue, str.count < n { issues.append(Issue(path: path, message: "shorter than \(n)")) }
            if let n = s["maxLength"]?.intValue, str.count > n { issues.append(Issue(path: path, message: "longer than \(n)")) }
            if case .string(let p)? = s["pattern"], str.range(of: p, options: .regularExpression) == nil {
                issues.append(Issue(path: path, message: "doesn't match \(p)"))
            }
        }
        if case .number(let n) = value {
            if let m = s["minimum"]?.numberValue, n < m { issues.append(Issue(path: path, message: "below \(m)")) }
            if let m = s["maximum"]?.numberValue, n > m { issues.append(Issue(path: path, message: "above \(m)")) }
            if let m = s["exclusiveMinimum"]?.numberValue, n <= m { issues.append(Issue(path: path, message: "not above \(m)")) }
        }
        if case .object(let o) = value {
            let props = s["properties"]?.objectValue ?? [:]
            for case .string(let key) in s["required"]?.arrayValue ?? [] where o[key] == nil {
                issues.append(Issue(path: path, message: "missing required '\(key)'"))
            }
            if let n = s["minProperties"]?.intValue, o.count < n { issues.append(Issue(path: path, message: "fewer than \(n) properties")) }
            for (key, sub) in o.sorted(by: { $0.key < $1.key }) {
                if let names = s["propertyNames"] {
                    issues += check(.string(key), names, base: base, root: root, path: "\(path).<name \(key)>")
                }
                if let ps = props[key] {
                    issues += check(sub, ps, base: base, root: root, path: "\(path).\(key)")
                } else if let ap = s["additionalProperties"] {
                    if case .bool(false) = ap { issues.append(Issue(path: path, message: "unexpected property '\(key)'")) }
                    else if case .object = ap { issues += check(sub, ap, base: base, root: root, path: "\(path).\(key)") }
                }
            }
        }
        if case .array(let a) = value {
            if let n = s["minItems"]?.intValue, a.count < n { issues.append(Issue(path: path, message: "fewer than \(n) items")) }
            if let n = s["maxItems"]?.intValue, a.count > n { issues.append(Issue(path: path, message: "more than \(n) items")) }
            if let items = s["items"] {
                for (i, item) in a.enumerated() { issues += check(item, items, base: base, root: root, path: "\(path)[\(i)]") }
            }
        }
        for sub in s["allOf"]?.arrayValue ?? [] { issues += check(value, sub, base: base, root: root, path: path) }
        if let any = s["anyOf"]?.arrayValue, !any.contains(where: { check(value, $0, base: base, root: root, path: path).isEmpty }) {
            issues.append(Issue(path: path, message: "matches none of anyOf"))
        }
        if let one = s["oneOf"]?.arrayValue {
            let matches = one.filter { check(value, $0, base: base, root: root, path: path).isEmpty }.count
            if matches != 1 { issues.append(Issue(path: path, message: "matches \(matches) of oneOf (needs exactly 1)")) }
        }
        if let cond = s["if"], check(value, cond, base: base, root: root, path: path).isEmpty, let then = s["then"] {
            issues += check(value, then, base: base, root: root, path: path)
        }
        return issues
    }

    private enum Resolution {
        case resolved(JSONValue, URL?, JSONValue)
        case failed(String)
    }

    private func resolve(_ ref: String, base: URL?, root: JSONValue) -> Resolution {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let filePart = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        var document = root
        var documentURL = base
        if !filePart.isEmpty {
            guard let loader, let base else { return .failed("cannot resolve \(ref) without a schema loader") }
            let url = URL(fileURLWithPath: filePart, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
            guard let loaded = loader.load(url) else { return .failed("cannot load \(url.path)") }
            document = loaded
            documentURL = url
        }
        var node = document
        for token in fragment.split(separator: "/") where !token.isEmpty {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = node[key] else { return .failed("unresolved $ref \(ref)") }
            node = next
        }
        return .resolved(node, documentURL, document)
    }

    static func typeMatches(_ value: JSONValue, _ t: JSONValue) -> Bool {
        if case .array(let types) = t { return types.contains { typeMatches(value, $0) } }
        switch (t.stringValue, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null),
             ("number", .number): return true
        case ("integer", .number): return value.isInteger
        default: return false
        }
    }

    static func same(_ a: JSONValue, _ b: JSONValue) -> Bool { a == b }

    static func describe(_ t: JSONValue) -> String {
        if case .array(let a) = t { return a.compactMap(\.stringValue).joined(separator: " or ") }
        return t.stringValue ?? "?"
    }
}

/// Loads and caches schema files for cross-file `$ref`s.
public final class SchemaLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [URL: JSONValue] = [:]

    public init() {}

    public func load(_ url: URL) -> JSONValue? {
        let key = url.standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let data = try? Data(contentsOf: key), let value = try? MESJSON.decoder.decode(JSONValue.self, from: data) else {
            return nil
        }
        cache[key] = value
        return value
    }
}
