import Foundation
import MESCore
import Observation

/// The state of one operation's form: the parameters a person has set, the model they chose, the extensions they
/// turned on and the text inputs they typed. It turns into a `JobRequest`; media inputs come from the host app
/// (drag and drop, a file panel, a previous result), which is why `request(media:)` takes them.
///
/// Only values the person set are sent. A field showing its schema `default` is left to the engine, which applies
/// the same default and reports it in `effective`.
@MainActor @Observable
public final class OperationFormModel {
    public let descriptor: Descriptor
    /// Top-level parameters in display order.
    public let fields: [FormField]

    /// Parameter values the person set, by name. Nested objects hold their own set values.
    public private(set) var values: [String: JSONValue] = [:]
    /// Text inputs (`prompt`, `instruction`, …), by input name.
    public var text: [String: String] = [:]
    /// The chosen model id; nil lets the engine choose (its default for the quality tier and policy).
    public var model: String?
    /// The policy sent with the request (Base §10.3).
    public var policy = Policy()
    /// Extensions turned on, by name, with their values.
    public private(set) var extensions: [String: JSONValue] = [:]
    /// Whether the advanced parameters are shown.
    public var showsAdvanced = false
    /// Where voice lists come from (Base §6.5). Without one, the `voice` widget takes a voice id as text.
    public var voiceSource: VoiceSource?
    /// The preset voices of `voicesModel`, once `loadVoices()` has run.
    public private(set) var voices: [Voice] = []
    /// The model `voices` were loaded for.
    public private(set) var voicesModel: String?
    /// Why the last voice list didn't load.
    public private(set) var voicesError: String?
    public private(set) var loadingVoices = false
    /// Ask for every output that can to stream as it's made (§7.1, §11). Sent only when `canStream`.
    public var stream = false

    public init(descriptor: Descriptor) {
        self.descriptor = descriptor
        fields = FormSchema.fields(of: descriptor.params)
    }

    // MARK: - Fields

    public var mainFields: [FormField] { fields.filter { !$0.advanced } }
    public var advancedFields: [FormField] { fields.filter(\.advanced) }

    /// Fields grouped by their `group` hint, ungrouped first, keeping order within each group.
    public static func grouped(_ fields: [FormField]) -> [(group: String?, fields: [FormField])] {
        var order: [String?] = []
        var byGroup: [String?: [FormField]] = [:]
        for f in fields {
            if byGroup[f.group] == nil { order.append(f.group) }
            byGroup[f.group, default: []].append(f)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    public var textInputs: [InputSpec] { descriptor.inputs.filter { $0.kind == .text } }
    public var mediaInputs: [InputSpec] { descriptor.inputs.filter { $0.kind != .text } }

    // MARK: - Values by path

    /// The value set at `path` (`["output", "bit_depth"]`), or nil when unset.
    public func value(at path: [String]) -> JSONValue? { Self.get(.object(values), path) }

    /// Sets (or with nil, clears) the value at `path`. Clearing the last value of a nested object removes the object,
    /// so an untouched optional object isn't sent.
    public func setValue(_ value: JSONValue?, at path: [String]) {
        guard case .object(let updated) = Self.set(.object(values), path, value) else { return }
        values = updated
    }

    /// Clears every parameter, the model, the extensions and streaming.
    public func reset() {
        values = [:]
        model = nil
        extensions = [:]
        stream = false
    }

    // MARK: - Extensions

    public func isEnabled(_ ext: ExtensionSpec) -> Bool { extensions[ext.name] != nil }

    /// Turning an extension on starts it from its schema's defaults and required fields.
    public func setEnabled(_ ext: ExtensionSpec, _ on: Bool) {
        extensions[ext.name] = on ? FormSchema.initialValue(ext.schema) : nil
    }

    public func extensionValue(_ ext: ExtensionSpec, at path: [String]) -> JSONValue? {
        Self.get(extensions[ext.name] ?? .object([:]), path)
    }

    public func setExtensionValue(_ ext: ExtensionSpec, _ value: JSONValue?, at path: [String]) {
        guard isEnabled(ext) else { return }
        extensions[ext.name] = Self.set(extensions[ext.name] ?? .object([:]), path, value) ?? .object([:])
    }

    // MARK: - Models

    /// The model the request names, or the descriptor's default.
    public var effectiveModel: ModelOffer? {
        if let model, let chosen = descriptor.models.first(where: { $0.id == model }) { return chosen }
        return descriptor.models.first { $0.isDefault == true } ?? descriptor.models.first
    }

    // MARK: - Voices and streaming

    /// Loads the effective model's voice list; a model without voices (`supports.voices` 0) has none to load. HTTP
    /// connections revalidate with the ETag, so calling this on every model change is cheap.
    public func loadVoices() async {
        guard let model = effectiveModel, model.voiceCount > 0, let voiceSource else {
            voices = []
            voicesModel = effectiveModel?.id
            voicesError = nil
            return
        }
        loadingVoices = true
        defer { loadingVoices = false }
        do {
            let list = try await voiceSource.voices(descriptor.operation, model.id)
            guard effectiveModel?.id == model.id else { return }          // the person chose another model meanwhile
            (voices, voicesModel, voicesError) = (list, model.id, nil)
        } catch {
            guard effectiveModel?.id == model.id else { return }
            (voices, voicesModel, voicesError) = ([], model.id, String(describing: error))
        }
    }

    /// What the `voice` widget shows: the effective model's voices, and how to play a sample.
    public var voiceChoices: VoiceChoices {
        VoiceChoices(voices: voicesModel == effectiveModel?.id ? voices : [], model: effectiveModel, loading: loadingVoices,
                     error: voicesError, sample: voiceSource?.sample)
    }

    /// The outputs whose spec can stream (§6: an `audio` output whose `max` is 1).
    public var streamableOutputs: [OutputSpec] { descriptor.outputs.filter { $0.stream != nil } }

    /// Whether the request can stream: a streamable output, and the chosen model streams (with none chosen, some offer
    /// does: streaming implies its model, §6.4).
    public var canStream: Bool {
        guard !streamableOutputs.isEmpty else { return false }
        if let model, let chosen = descriptor.models.first(where: { $0.id == model }) { return chosen.streams }
        return descriptor.models.contains(where: \.streams)
    }

    /// Models the policy rules out (a commercial-use policy excludes `no` and `unknown`).
    public func isExcluded(_ offer: ModelOffer) -> Bool {
        policy.effectiveLicense == .commercialUse && offer.license.commercialUse != .yes
    }

    // MARK: - Validation and the request

    /// Problems with the current values, from the descriptor's schema, keyed by top-level parameter.
    public var issues: [String: String] {
        var byField: [String: String] = [:]
        for issue in SchemaValidator().validate(.object(values), against: descriptor.params) {
            let parts = issue.path.split(separator: ".").dropFirst()
            let key = parts.first.map(String.init) ?? ""
            if byField[key] == nil { byField[key] = issue.message }
        }
        for ext in descriptor.extensions ?? [] {
            guard let value = extensions[ext.name] else { continue }
            if let issue = SchemaValidator().validate(value, against: ext.schema).first { byField[ext.name] = issue.message }
        }
        // A voice the chosen model doesn't list is refused (§6.5 rule 2); say so before sending.
        let choices = voiceChoices
        for field in fields where field.widget == .voice {
            guard let id = values[field.name]?.stringValue, !choices.voices.isEmpty, !choices.voices.contains(where: { $0.id == id }),
                  byField[field.name] == nil else { continue }
            byField[field.name] = "\(choices.model?.title ?? "This model") has no voice \(id)."
        }
        return byField
    }

    /// Required inputs still missing. `media` names the media inputs the host has filled.
    public func missingInputs(media: Set<String>) -> [InputSpec] {
        descriptor.inputs.filter { spec in
            guard spec.required else { return false }
            return spec.kind == .text ? (text[spec.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : !media.contains(spec.name)
        }
    }

    /// The request this form describes. `media` are the host's media inputs by name.
    public func request(media: [String: RequestInput] = [:], clientRef: String? = nil) -> JobRequest {
        var inputs = media
        for (name, value) in text where !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputs[name] = .text(value)
        }
        let usesPolicy = policy.license != nil || policy.remote != nil
        let streams = stream && canStream ? streamableOutputs.map { StreamRequest(output: $0.name) } : nil
        return JobRequest(operation: descriptor.operation, inputs: inputs.isEmpty ? nil : inputs,
                          params: values.isEmpty ? nil : values, model: model, policy: usesPolicy ? policy : nil,
                          extensions: extensions.isEmpty ? nil : extensions, stream: streams, clientRef: clientRef)
    }

    // MARK: - Path plumbing

    static func get(_ root: JSONValue, _ path: [String]) -> JSONValue? {
        var node: JSONValue? = root
        for key in path { node = node?[key] }
        return node
    }

    static func set(_ root: JSONValue, _ path: [String], _ value: JSONValue?) -> JSONValue? {
        guard let key = path.first else { return value }
        var object = root.objectValue ?? [:]
        if path.count == 1 {
            object[key] = value
        } else {
            let child = set(object[key] ?? .object([:]), Array(path.dropFirst()), value)
            if let child, child != .object([:]) { object[key] = child } else { object[key] = nil }
        }
        return .object(object)
    }
}
