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
}

extension MediaEngine {
    public func validate(_ request: JobRequest, descriptor: Descriptor) throws {
        if descriptor.profile == ImageProfile.id { try ImageProfileRules.validate(request, descriptor: descriptor) }
    }
    public func residentModels() async -> [String] { [] }
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

    public init(outputs: [ProducedOutput], effective: [String: JSONValue] = [:], seed: Int? = nil, warnings: [Warning] = []) {
        self.outputs = outputs; self.effective = effective; self.seed = seed; self.warnings = warnings
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
    }
}
