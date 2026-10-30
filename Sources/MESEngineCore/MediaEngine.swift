import Foundation
import MESCore

/// What an engine author implements. MESEngineKit handles everything else in Base 0.1: routes, validation against
/// descriptors, model choice by policy and quality tier, uploads and grants, the spool and retention, events and
/// provenance. The engine only describes its operations and runs one job at a time it's given.
public protocol MediaEngine: Sendable {
    /// The engine's operations. Served as `GET {path}/operations`; requests are validated against them.
    func descriptors() async -> [Descriptor]

    /// Profile-specific checks beyond the descriptor's params schema, run at submit (e.g. Image: `size` and
    /// `aspect` together is 400). Throw a `MESError`. The default applies the Image profile's table-driven rules.
    func validate(_ request: JobRequest, descriptor: Descriptor) throws

    /// Runs one job. Read inputs from `context.inputs`, write output files into `context.outputDirectory`, report
    /// progress and warnings through `context.reporter`. Throw a `MESError` for a failure the client should see.
    /// Honour Task cancellation: a released job is cancelled.
    func run(_ context: RunContext) async throws -> RunOutput

    /// Model ids currently in memory, for `GET {path}/health`.
    func residentModels() async -> [String]

    /// When a request names no model: a better default for its params than `kitChoice`, the kit's default for the
    /// quality tier (e.g. restore choosing a network by `kind`). Return nil to keep it. The kit uses the answer only
    /// if it is one of `candidates`: the descriptor's offers for the tier that aren't `named_only` and that the
    /// request's policy allows. Runs at submit, before the plan, so the plan and provenance name what runs.
    func defaultModel(for request: JobRequest, descriptor: Descriptor, kitChoice: ModelOffer,
                      candidates: [ModelOffer]) -> ModelOffer?
}

extension MediaEngine {
    public func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        if descriptor.profile == ImageProfile.id { try ImageProfileRules.validate(request, descriptor: descriptor) }
    }
    public func residentModels() async -> [String] { [] }
    public func defaultModel(for request: JobRequest, descriptor: Descriptor, kitChoice: ModelOffer,
                             candidates: [ModelOffer]) -> ModelOffer? { nil }
}

/// One input as the engine receives it: text, a file in the job's spool, or JSON data.
public enum RunInput: Sendable, Equatable {
    case text(String)
    case file(URL, mediaType: String)
    case data(JSONValue)

    public var fileURL: URL? { if case .file(let url, _) = self { return url }; return nil }
    public var text: String? { if case .text(let s) = self { return s }; return nil }
    public var data: JSONValue? { if case .data(let v) = self { return v }; return nil }
}

public struct RunContext: Sendable {
    public let jobID: String
    public let operation: String
    public let descriptor: Descriptor
    /// The model the kit chose (or the client named), already checked against the licence and remote policy.
    public let model: ModelOffer
    /// The adapters the request asked for (Base §6.3), in its order, each the model's offer with the strength to run
    /// at: already checked against the model's list, its `max_adapters`, each range and the licence policy.
    public let adapters: [AdapterChoice]
    public let quality: QualityTier
    /// The request's params, validated against the descriptor.
    public let params: [String: JSONValue]
    public let extensions: [String: JSONValue]
    public let inputs: [String: [RunInput]]
    public let policy: Policy
    /// Write outputs here. The kit hashes, serves and purges them.
    public let outputDirectory: URL
    public let reporter: RunReporter

    public func input(_ name: String) -> RunInput? { inputs[name]?.first }
    public func param(_ name: String) -> JSONValue? { params[name] }
}

/// One adapter a job applies: the model's offer of it and the strength to run it at (the request's, or the default).
public struct AdapterChoice: Sendable, Equatable {
    public let offer: AdapterOffer
    public let strength: Double
    public init(offer: AdapterOffer, strength: Double) { self.offer = offer; self.strength = strength }
    public var id: String { offer.id }
}

/// Progress, warnings and previews from a running job, delivered as events.
public struct RunReporter: Sendable {
    let progressSink: @Sendable (JobProgress) async -> Void
    let warningSink: @Sendable (Warning) async -> Void
    let previewSink: @Sendable (Data, String) async -> Void

    public init(progress: @escaping @Sendable (JobProgress) async -> Void,
                warning: @escaping @Sendable (Warning) async -> Void,
                preview: @escaping @Sendable (Data, String) async -> Void) {
        progressSink = progress; warningSink = warning; previewSink = preview
    }

    public func progress(_ stage: Stage = .running, step: Int? = nil, steps: Int? = nil, fraction: Double? = nil,
                         message: String? = nil) async {
        var f = fraction
        if f == nil, let step, let steps, steps > 0 { f = Double(step) / Double(steps) }
        await progressSink(JobProgress(stage: stage, step: step, steps: steps, fraction: f, message: message))
    }

    public func warn(_ code: String, _ message: String, param: String? = nil) async {
        await warningSink(Warning(code: code, message: message, param: param))
    }

    /// A small preview (≤ 256 KiB is inlined in the event).
    public func preview(_ data: Data, mediaType: String) async { await previewSink(data, mediaType) }

    public static let none = RunReporter(progress: { _ in }, warning: { _ in }, preview: { _, _ in })
}

/// One produced output: a file the engine wrote, or a JSON value (`data` kind).
public struct ProducedOutput: Sendable {
    public var name: String
    public var kind: Kind
    public var mediaType: String
    public var file: URL?
    public var value: JSONValue?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var fps: Double?

    public static func file(_ url: URL, name: String, kind: Kind, mediaType: String, width: Int? = nil, height: Int? = nil,
                            durationSeconds: Double? = nil, fps: Double? = nil) -> ProducedOutput {
        ProducedOutput(name: name, kind: kind, mediaType: mediaType, file: url, value: nil, width: width, height: height,
                       durationSeconds: durationSeconds, fps: fps)
    }

    public static func data(_ value: JSONValue, name: String) -> ProducedOutput {
        ProducedOutput(name: name, kind: .data, mediaType: "application/json", file: nil, value: value)
    }
}

public struct RunOutput: Sendable {
    public var outputs: [ProducedOutput]
    /// Normalized parameters actually used. Merged over the request's; model-specific detail may go under
    /// `model_params`.
    public var effective: [String: JSONValue]
    public var seed: Int?
    public var warnings: [Warning]
    /// Models that shaped the result without producing it, e.g. a prompt enhancer (Base §10.1), for provenance. The
    /// engine checks them against `context.policy` (Base §10.3) and leaves out one that doesn't satisfy it.
    public var helpers: [HelperRef]
    /// The pinned revisions of the weights that ran, by model or adapter id, for provenance's `revision` fields.
    public var revisions: [String: String]

    public init(outputs: [ProducedOutput], effective: [String: JSONValue] = [:], seed: Int? = nil, warnings: [Warning] = [],
                helpers: [HelperRef] = [], revisions: [String: String] = [:]) {
        self.outputs = outputs; self.effective = effective; self.seed = seed; self.warnings = warnings; self.helpers = helpers
        self.revisions = revisions
    }
}

/// Table-driven Image profile checks (spec/profiles/image.md).
public enum ImageProfileRules {
    public static func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        let params = request.params ?? [:]
        if params[ImageProfile.Param.size] != nil, params[ImageProfile.Param.aspect] != nil {
            throw MESError(.invalidRequest, "size and aspect are mutually exclusive", param: ImageProfile.Param.aspect)
        }
        if let spec = ImageProfile.operations.operations[descriptor.operation], let oneOf = spec.requiresOneOf {
            let given = Set((request.inputs ?? [:]).keys)
            if given.isDisjoint(with: oneOf) {
                throw MESError(.invalidRequest, "\(descriptor.operation) needs one of: \(oneOf.joined(separator: ", "))",
                               param: oneOf.first)
            }
        }
        try validateSlots(request, descriptor: descriptor)
        // §3.2: `decompose`'s outputs always include its layers (a rule outside the vocabulary schema's subset).
        if descriptor.operation == "image.decompose", let outputs = params[ImageProfile.Param.outputs]?.arrayValue,
           !outputs.contains(.string("layers")) {
            throw MESError(.invalidRequest, "image.decompose's outputs must include layers; composite is an addition to them.",
                           param: ImageProfile.Param.outputs)
        }
    }

    /// §1.10: `ic` adapters' required slots are filled, in order, from the operation's adapter input.
    static func validateSlots(_ request: JobRequest, descriptor: Descriptor) throws {
        let offers = descriptor.models.flatMap { $0.adapters ?? [] }
        let needed = (request.adapters ?? []).reduce(0) { sum, a in sum + (offers.first { $0.id == a.id }?.requiredSlots ?? 0) }
        guard needed > 0 else { return }
        guard let input = ImageProfile.operations.operations[descriptor.operation]?.adapterInput else {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) has no input for in-context adapters' slots.",
                           param: "adapters")
        }
        let given = request.inputs?[input]?.values.count ?? 0
        if given < needed {
            throw MESError(.invalidRequest, "The adapters asked for need \(needed) value\(needed == 1 ? "" : "s") in '\(input)', "
                           + "one per slot in order; the request has \(given).", param: input)
        }
    }
}
