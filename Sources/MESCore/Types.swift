import Foundation

// Wire types for MES Base 0.1 (spec/base.md, schemas/v0/base). Field names follow the schemas exactly; every
// type round-trips the examples in examples/v0 (MESCoreTests).

// MARK: - Registries (§18)

public enum Kind: String, Codable, Sendable, CaseIterable { case text, image, mask, video, audio, data }
public enum QualityTier: String, Codable, Sendable, CaseIterable { case draft, standard, best }
public enum JobState: String, Codable, Sendable, CaseIterable { case received, fetching, waiting, running, holding, purged }
public enum Outcome: String, Codable, Sendable, CaseIterable { case succeeded, failed, cancelled, expired }
public enum Stage: String, Codable, Sendable, CaseIterable { case fetching, waiting, preparing, running, finishing }
public enum Feature: String, Codable, Sendable, CaseIterable { case uploads, grants, sse, websocket, mcp, previews, pairing }
public enum AuthMode: String, Codable, Sendable { case paired, open }

// MARK: - Licence, providers, warnings (§10)

/// `commercial_use` is `true`, `false` or the string `"unknown"`.
public enum CommercialUse: Sendable, Equatable, Codable {
    case yes, no, unknown

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = b ? .yes : .no; return }
        guard try c.decode(String.self) == "unknown" else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "commercial_use must be true, false or \"unknown\"")
        }
        self = .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .yes: try c.encode(true)
        case .no: try c.encode(false)
        case .unknown: try c.encode("unknown")
        }
    }
}

public struct License: Codable, Sendable, Equatable {
    public var spdx: String
    public var commercialUse: CommercialUse
    public var termsURL: String?
    public var notice: String?
    public var acceptedRequired: Bool?

    public init(spdx: String, commercialUse: CommercialUse, termsURL: String? = nil, notice: String? = nil,
                acceptedRequired: Bool? = nil) {
        self.spdx = spdx; self.commercialUse = commercialUse; self.termsURL = termsURL
        self.notice = notice; self.acceptedRequired = acceptedRequired
    }

    enum CodingKeys: String, CodingKey {
        case spdx, notice
        case commercialUse = "commercial_use"
        case termsURL = "terms_url"
        case acceptedRequired = "accepted_required"
    }

    public static let apache2 = License(spdx: "Apache-2.0", commercialUse: .yes,
                                        termsURL: "https://www.apache.org/licenses/LICENSE-2.0")
}

public struct RemoteProvider: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var billed: Bool
    public init(id: String, name: String, billed: Bool) { self.id = id; self.name = name; self.billed = billed }
}

public struct Warning: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var param: String?
    public init(code: String, message: String, param: String? = nil) { self.code = code; self.message = message; self.param = param }
}

public struct ModelRef: Codable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var revision: String?
    public var license: License
    public init(id: String, title: String? = nil, revision: String? = nil, license: License) {
        self.id = id; self.title = title; self.revision = revision; self.license = license
    }
}

public struct JobProgress: Codable, Sendable, Equatable {
    public var stage: Stage
    public var step: Int?
    public var steps: Int?
    public var fraction: Double?
    public var message: String?
    public init(stage: Stage, step: Int? = nil, steps: Int? = nil, fraction: Double? = nil, message: String? = nil) {
        self.stage = stage; self.step = step; self.steps = steps; self.fraction = fraction; self.message = message
    }
}

// MARK: - Engine information (§4)

public struct EngineInfo: Codable, Sendable, Equatable {
    public struct Implementation: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public var url: String?
        public init(name: String, version: String, url: String? = nil) { self.name = name; self.version = version; self.url = url }
    }
    public struct ProfileVersions: Codable, Sendable, Equatable {
        public var id: String
        public var versions: [String]
        public init(id: String, versions: [String]) { self.id = id; self.versions = versions }
    }
    public struct TLS: Codable, Sendable, Equatable {
        public var fingerprintSHA256: String
        enum CodingKeys: String, CodingKey { case fingerprintSHA256 = "fingerprint_sha256" }
        public init(fingerprintSHA256: String) { self.fingerprintSHA256 = fingerprintSHA256 }
    }
    public struct Limits: Codable, Sendable, Equatable {
        public var maxUploadBytes: Int
        public var maxInlineBytes: Int
        public var maxQueuedJobsPerClient: Int?
        enum CodingKeys: String, CodingKey {
            case maxUploadBytes = "max_upload_bytes"
            case maxInlineBytes = "max_inline_bytes"
            case maxQueuedJobsPerClient = "max_queued_jobs_per_client"
        }
        public init(maxUploadBytes: Int, maxInlineBytes: Int, maxQueuedJobsPerClient: Int? = nil) {
            self.maxUploadBytes = maxUploadBytes; self.maxInlineBytes = maxInlineBytes
            self.maxQueuedJobsPerClient = maxQueuedJobsPerClient
        }
    }
    public struct Retention: Codable, Sendable, Equatable {
        public var outputsTTLSeconds: Int
        public var jobRecordTTLSeconds: Int
        enum CodingKeys: String, CodingKey {
            case outputsTTLSeconds = "outputs_ttl_s"
            case jobRecordTTLSeconds = "job_record_ttl_s"
        }
        public init(outputsTTLSeconds: Int, jobRecordTTLSeconds: Int) {
            self.outputsTTLSeconds = outputsTTLSeconds; self.jobRecordTTLSeconds = jobRecordTTLSeconds
        }
    }

    public var id: String
    public var name: String
    public var implementation: Implementation
    public var baseVersions: [String]
    public var profiles: [ProfileVersions]
    public var auth: AuthMode
    public var tls: TLS?
    public var features: [Feature]
    public var limits: Limits
    public var retention: Retention

    enum CodingKeys: String, CodingKey {
        case id, name, implementation, profiles, auth, tls, features, limits, retention
        case baseVersions = "base_versions"
    }

    public init(id: String, name: String, implementation: Implementation, baseVersions: [String],
                profiles: [ProfileVersions], auth: AuthMode, tls: TLS? = nil, features: [Feature], limits: Limits,
                retention: Retention) {
        self.id = id; self.name = name; self.implementation = implementation; self.baseVersions = baseVersions
        self.profiles = profiles; self.auth = auth; self.tls = tls; self.features = features
        self.limits = limits; self.retention = retention
    }
}

// MARK: - Descriptors (§6)

public struct InputSpec: Codable, Sendable, Equatable {
    public var name: String
    public var kind: Kind
    public var required: Bool
    public var min: Int?
    public var max: Int?
    public var mediaTypes: [String]?
    public var notes: String?
    enum CodingKeys: String, CodingKey { case name, kind, required, min, max, notes; case mediaTypes = "media_types" }
    public init(name: String, kind: Kind, required: Bool, min: Int? = nil, max: Int? = nil, mediaTypes: [String]? = nil,
                notes: String? = nil) {
        self.name = name; self.kind = kind; self.required = required; self.min = min; self.max = max
        self.mediaTypes = mediaTypes; self.notes = notes
    }
}

public struct OutputSpec: Codable, Sendable, Equatable {
    public var name: String
    public var kind: Kind
    public var mediaTypes: [String]?
    public var min: Int?
    public var max: Int?
    enum CodingKeys: String, CodingKey { case name, kind, min, max; case mediaTypes = "media_types" }
    public init(name: String, kind: Kind, mediaTypes: [String]? = nil, min: Int? = nil, max: Int? = nil) {
        self.name = name; self.kind = kind; self.mediaTypes = mediaTypes; self.min = min; self.max = max
    }
}

public struct ModelOffer: Codable, Sendable, Equatable {
    public enum MemoryClass: String, Codable, Sendable { case small, medium, large, xlarge }
    public enum SpeedClass: String, Codable, Sendable { case fast, standard, slow }
    public var id: String
    public var title: String
    public var license: License
    public var memoryClass: MemoryClass?
    public var speedClass: SpeedClass?
    public var qualityTiers: [QualityTier]
    public var isDefault: Bool?
    /// Never chosen by default: runs only when a request names it (Base §6 rule 2), e.g. research-licensed models.
    public var namedOnly: Bool?
    public var remoteProvider: RemoteProvider?
    enum CodingKeys: String, CodingKey {
        case id, title, license
        case memoryClass = "memory_class"
        case speedClass = "speed_class"
        case qualityTiers = "quality_tiers"
        case isDefault = "default"
        case namedOnly = "named_only"
        case remoteProvider = "remote_provider"
    }
    public init(id: String, title: String, license: License, memoryClass: MemoryClass? = nil, speedClass: SpeedClass? = nil,
                qualityTiers: [QualityTier], isDefault: Bool? = nil, namedOnly: Bool? = nil, remoteProvider: RemoteProvider? = nil) {
        self.id = id; self.title = title; self.license = license; self.memoryClass = memoryClass
        self.speedClass = speedClass; self.qualityTiers = qualityTiers; self.isDefault = isDefault
        self.namedOnly = namedOnly; self.remoteProvider = remoteProvider
    }
    public var ref: ModelRef { ModelRef(id: id, title: title, license: license) }
}

public struct ExtensionSpec: Codable, Sendable, Equatable {
    public var name: String
    public var title: String
    public var schema: JSONValue
    public init(name: String, title: String, schema: JSONValue) { self.name = name; self.title = title; self.schema = schema }
}

public struct Descriptor: Codable, Sendable, Equatable {
    public struct Limits: Codable, Sendable, Equatable {
        public var maxWidth: Int?
        public var maxHeight: Int?
        public var maxMegapixels: Double?
        public var maxDurationSeconds: Double?
        public var maxInputs: Int?
        public var maxCount: Int?
        enum CodingKeys: String, CodingKey {
            case maxWidth = "max_width", maxHeight = "max_height", maxMegapixels = "max_megapixels"
            case maxDurationSeconds = "max_duration_s", maxInputs = "max_inputs", maxCount = "max_count"
        }
        public init(maxWidth: Int? = nil, maxHeight: Int? = nil, maxMegapixels: Double? = nil,
                    maxDurationSeconds: Double? = nil, maxInputs: Int? = nil, maxCount: Int? = nil) {
            self.maxWidth = maxWidth; self.maxHeight = maxHeight; self.maxMegapixels = maxMegapixels
            self.maxDurationSeconds = maxDurationSeconds; self.maxInputs = maxInputs; self.maxCount = maxCount
        }
    }
    public struct Remote: Codable, Sendable, Equatable {
        public var possible: Bool
        public var providers: [RemoteProvider]?
        public init(possible: Bool, providers: [RemoteProvider]? = nil) { self.possible = possible; self.providers = providers }
    }
    public struct Retention: Codable, Sendable, Equatable {
        public var outputsTTLSeconds: Int?
        enum CodingKeys: String, CodingKey { case outputsTTLSeconds = "outputs_ttl_s" }
        public init(outputsTTLSeconds: Int?) { self.outputsTTLSeconds = outputsTTLSeconds }
    }

    public var operation: String
    public var profile: String
    public var profileVersion: String
    public var title: String
    public var summary: String?
    public var inputs: [InputSpec]
    /// A JSON Schema (draft 2020-12) object with `x-mes-ui` hints on each property.
    public var params: JSONValue
    public var outputs: [OutputSpec]
    public var limits: Limits?
    public var qualityTiers: [QualityTier]
    public var models: [ModelOffer]
    public var extensions: [ExtensionSpec]?
    public var remote: Remote?
    public var retention: Retention?

    enum CodingKeys: String, CodingKey {
        case operation, profile, title, summary, inputs, params, outputs, limits, models, extensions, remote, retention
        case profileVersion = "profile_version"
        case qualityTiers = "quality_tiers"
    }

    public init(operation: String, profile: String, profileVersion: String, title: String, summary: String? = nil,
                inputs: [InputSpec], params: JSONValue, outputs: [OutputSpec], limits: Limits? = nil,
                qualityTiers: [QualityTier], models: [ModelOffer], extensions: [ExtensionSpec]? = nil,
                remote: Remote? = nil, retention: Retention? = nil) {
        self.operation = operation; self.profile = profile; self.profileVersion = profileVersion; self.title = title
        self.summary = summary; self.inputs = inputs; self.params = params; self.outputs = outputs
        self.limits = limits; self.qualityTiers = qualityTiers; self.models = models; self.extensions = extensions
        self.remote = remote; self.retention = retention
    }
}

public struct OperationsList: Codable, Sendable, Equatable {
    public var operations: [Descriptor]
    public var etag: String
    public init(operations: [Descriptor], etag: String) { self.operations = operations; self.etag = etag }
}

// MARK: - Job requests (§7.1, §8, §9)

public struct Policy: Codable, Sendable, Equatable {
    public enum LicensePolicy: String, Codable, Sendable { case any, commercialUse = "commercial-use" }
    public enum RemotePolicy: String, Codable, Sendable { case forbid, allow }
    public var license: LicensePolicy?
    public var remote: RemotePolicy?
    public init(license: LicensePolicy? = nil, remote: RemotePolicy? = nil) { self.license = license; self.remote = remote }
    public var effectiveLicense: LicensePolicy { license ?? .any }
    public var effectiveRemote: RemotePolicy { remote ?? .forbid }

    /// Whether `offer` may run under this policy (Base §10.2, §10.3).
    public func allows(_ offer: ModelOffer) -> Bool {
        if effectiveLicense == .commercialUse, offer.license.commercialUse != .yes { return false }
        if offer.remoteProvider != nil, effectiveRemote != .allow { return false }
        return true
    }
}

public struct Grant: Codable, Sendable, Equatable {
    public var url: String
    public var token: String
    public var mediaType: String
    public var bytes: Int?
    public var sha256: String?
    enum CodingKeys: String, CodingKey { case url, token, bytes, sha256; case mediaType = "media_type" }
    public init(url: String, token: String, mediaType: String, bytes: Int? = nil, sha256: String? = nil) {
        self.url = url; self.token = token; self.mediaType = mediaType; self.bytes = bytes; self.sha256 = sha256
    }
}

/// One media (or data) input value.
public enum InputValue: Sendable, Equatable, Codable {
    case inline(mediaType: String, data: Data)
    case upload(String)
    case grant(Grant)
    case data(JSONValue)

    enum Keys: String, CodingKey { case inline, upload, grant, data }
    struct Inline: Codable { var media_type: String; var data: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "an input value has exactly one of inline, upload, grant, data"))
        }
        switch key {
        case .inline:
            let i = try c.decode(Inline.self, forKey: .inline)
            guard let bytes = Data(base64Encoded: i.data) else {
                throw DecodingError.dataCorruptedError(forKey: .inline, in: c, debugDescription: "inline data is not base64")
            }
            self = .inline(mediaType: i.media_type, data: bytes)
        case .upload: self = .upload(try c.decode(String.self, forKey: .upload))
        case .grant: self = .grant(try c.decode(Grant.self, forKey: .grant))
        case .data: self = .data(try c.decode(JSONValue.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .inline(let mt, let d): try c.encode(Inline(media_type: mt, data: d.base64EncodedString()), forKey: .inline)
        case .upload(let id): try c.encode(id, forKey: .upload)
        case .grant(let g): try c.encode(g, forKey: .grant)
        case .data(let v): try c.encode(v, forKey: .data)
        }
    }
}

/// A named input in a request: text, one value, or several.
public enum RequestInput: Sendable, Equatable, Codable {
    case text(String)
    case one(InputValue)
    case many([InputValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s) }
        else if let a = try? c.decode([InputValue].self) { self = .many(a) }
        else { self = .one(try c.decode(InputValue.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .one(let v): try c.encode(v)
        case .many(let a): try c.encode(a)
        }
    }

    public var values: [InputValue] {
        switch self {
        case .text: return []
        case .one(let v): return [v]
        case .many(let a): return a
        }
    }
}

public struct JobRequest: Codable, Sendable, Equatable {
    public var operation: String
    public var inputs: [String: RequestInput]?
    public var params: [String: JSONValue]?
    public var model: String?
    public var policy: Policy?
    public var extensions: [String: JSONValue]?
    public var clientRef: String?
    enum CodingKeys: String, CodingKey { case operation, inputs, params, model, policy, extensions; case clientRef = "client_ref" }
    public init(operation: String, inputs: [String: RequestInput]? = nil, params: [String: JSONValue]? = nil,
                model: String? = nil, policy: Policy? = nil, extensions: [String: JSONValue]? = nil, clientRef: String? = nil) {
        self.operation = operation; self.inputs = inputs; self.params = params; self.model = model
        self.policy = policy; self.extensions = extensions; self.clientRef = clientRef
    }
}

public struct Upload: Codable, Sendable, Equatable {
    public var uploadID: String
    public var mediaType: String
    public var bytes: Int
    public var sha256: String
    public var expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case bytes, sha256
        case uploadID = "upload_id", mediaType = "media_type", expiresAt = "expires_at"
    }
    public init(uploadID: String, mediaType: String, bytes: Int, sha256: String, expiresAt: Date) {
        self.uploadID = uploadID; self.mediaType = mediaType; self.bytes = bytes; self.sha256 = sha256; self.expiresAt = expiresAt
    }
}

// MARK: - Jobs (§7.2, §10)

public struct Output: Codable, Sendable, Equatable {
    public var index: Int
    public var name: String
    public var kind: Kind
    public var mediaType: String
    public var bytes: Int
    public var sha256: String
    public var href: String
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    public var fps: Double?
    public var value: JSONValue?
    enum CodingKeys: String, CodingKey {
        case index, name, kind, bytes, sha256, href, width, height, fps, value
        case mediaType = "media_type", durationSeconds = "duration_s"
    }
    public init(index: Int, name: String, kind: Kind, mediaType: String, bytes: Int, sha256: String, href: String,
                width: Int? = nil, height: Int? = nil, durationSeconds: Double? = nil, fps: Double? = nil, value: JSONValue? = nil) {
        self.index = index; self.name = name; self.kind = kind; self.mediaType = mediaType; self.bytes = bytes
        self.sha256 = sha256; self.href = href; self.width = width; self.height = height
        self.durationSeconds = durationSeconds; self.fps = fps; self.value = value
    }
}

public struct Plan: Codable, Sendable, Equatable {
    public var model: ModelRef
    public var effective: [String: JSONValue]
    public var remoteProvider: RemoteProvider?
    enum CodingKeys: String, CodingKey { case model, effective; case remoteProvider = "remote_provider" }
    public init(model: ModelRef, effective: [String: JSONValue], remoteProvider: RemoteProvider? = nil) {
        self.model = model; self.effective = effective; self.remoteProvider = remoteProvider
    }
}

public struct Provenance: Codable, Sendable, Equatable {
    public struct Engine: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var implementation: String
        public var version: String
        public init(id: String, name: String, implementation: String, version: String) {
            self.id = id; self.name = name; self.implementation = implementation; self.version = version
        }
    }
    public struct Timings: Codable, Sendable, Equatable {
        public var receivedAt: Date
        public var startedAt: Date?
        public var finishedAt: Date?
        public var queueMs: Int?
        public var prepareMs: Int?
        public var runMs: Int?
        enum CodingKeys: String, CodingKey {
            case receivedAt = "received_at", startedAt = "started_at", finishedAt = "finished_at"
            case queueMs = "queue_ms", prepareMs = "prepare_ms", runMs = "run_ms"
        }
        public init(receivedAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil, queueMs: Int? = nil,
                    prepareMs: Int? = nil, runMs: Int? = nil) {
            self.receivedAt = receivedAt; self.startedAt = startedAt; self.finishedAt = finishedAt
            self.queueMs = queueMs; self.prepareMs = prepareMs; self.runMs = runMs
        }
    }
    public var engine: Engine
    public var operation: String
    public var profileVersion: String
    public var model: ModelRef
    public var remoteProvider: RemoteProvider?
    public var seed: Int?
    public var timings: Timings
    enum CodingKeys: String, CodingKey {
        case engine, operation, model, seed, timings
        case profileVersion = "profile_version", remoteProvider = "remote_provider"
    }
    public init(engine: Engine, operation: String, profileVersion: String, model: ModelRef,
                remoteProvider: RemoteProvider? = nil, seed: Int? = nil, timings: Timings) {
        self.engine = engine; self.operation = operation; self.profileVersion = profileVersion; self.model = model
        self.remoteProvider = remoteProvider; self.seed = seed; self.timings = timings
    }
}

public struct JobResult: Codable, Sendable, Equatable {
    public var outputs: [Output]
    public var effective: [String: JSONValue]
    public var provenance: Provenance
    public init(outputs: [Output], effective: [String: JSONValue], provenance: Provenance) {
        self.outputs = outputs; self.effective = effective; self.provenance = provenance
    }
}

public struct Job: Codable, Sendable, Equatable {
    public struct Retention: Codable, Sendable, Equatable {
        public var outputsExpireAt: Date?
        public var recordExpiresAt: Date
        enum CodingKeys: String, CodingKey { case outputsExpireAt = "outputs_expire_at", recordExpiresAt = "record_expires_at" }
        public init(outputsExpireAt: Date? = nil, recordExpiresAt: Date) {
            self.outputsExpireAt = outputsExpireAt; self.recordExpiresAt = recordExpiresAt
        }
    }
    public var id: String
    public var operation: String
    public var clientRef: String?
    public var state: JobState
    public var outcome: Outcome?
    public var plan: Plan?
    public var progress: JobProgress?
    public var warnings: [Warning]
    public var result: JobResult?
    public var error: MESError?
    public var retention: Retention
    public var createdAt: Date
    public var updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case id, operation, state, outcome, plan, progress, warnings, result, error, retention
        case clientRef = "client_ref", createdAt = "created_at", updatedAt = "updated_at"
    }
    public init(id: String, operation: String, clientRef: String? = nil, state: JobState, outcome: Outcome? = nil,
                plan: Plan? = nil, progress: JobProgress? = nil, warnings: [Warning] = [], result: JobResult? = nil,
                error: MESError? = nil, retention: Retention, createdAt: Date, updatedAt: Date) {
        self.id = id; self.operation = operation; self.clientRef = clientRef; self.state = state; self.outcome = outcome
        self.plan = plan; self.progress = progress; self.warnings = warnings; self.result = result; self.error = error
        self.retention = retention; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

// MARK: - Events (§11)

public enum EventType: String, Codable, Sendable, CaseIterable {
    case state = "job.state", plan = "job.plan", progress = "job.progress", preview = "job.preview"
    case warning = "job.warning", outputReady = "job.output_ready", ended = "job.ended"
    case engineHealth = "engine.health", operationsChanged = "engine.operations_changed"
}

public struct Event: Codable, Sendable, Equatable {
    public var type: EventType
    public var job: String?
    public var clientRef: String?
    public var seq: Int
    public var time: Date
    public var data: JSONValue
    enum CodingKeys: String, CodingKey { case type, job, seq, time, data; case clientRef = "client_ref" }
    public init(type: EventType, job: String?, clientRef: String? = nil, seq: Int, time: Date, data: JSONValue) {
        self.type = type; self.job = job; self.clientRef = clientRef; self.seq = seq; self.time = time; self.data = data
    }
}

// MARK: - Health (§14)

public struct Health: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ok, degraded, unavailable }
    public struct Memory: Codable, Sendable, Equatable {
        public var headroomBytes: Int?
        public var memoryClass: ModelOffer.MemoryClass?
        enum CodingKeys: String, CodingKey { case headroomBytes = "headroom_bytes", memoryClass = "class" }
        public init(headroomBytes: Int? = nil, memoryClass: ModelOffer.MemoryClass? = nil) {
            self.headroomBytes = headroomBytes; self.memoryClass = memoryClass
        }
    }
    public var status: Status
    public var queueDepth: Int
    public var running: String?
    public var residentModels: [String]
    public var memory: Memory?
    public var estimatedWaitSeconds: Double?
    enum CodingKeys: String, CodingKey {
        case status, running, memory
        case queueDepth = "queue_depth", residentModels = "resident_models", estimatedWaitSeconds = "estimated_wait_s"
    }
    public init(status: Status, queueDepth: Int, running: String? = nil, residentModels: [String], memory: Memory? = nil,
                estimatedWaitSeconds: Double? = nil) {
        self.status = status; self.queueDepth = queueDepth; self.running = running; self.residentModels = residentModels
        self.memory = memory; self.estimatedWaitSeconds = estimatedWaitSeconds
    }
}

// MARK: - Pairing (§5)

public struct PairingRequest: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientName: String
    public var clientKey: String
    public var clientNonce: String
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id", clientName = "client_name", clientKey = "client_key", clientNonce = "client_nonce"
    }
    public init(clientID: String, clientName: String, clientKey: String, clientNonce: String) {
        self.clientID = clientID; self.clientName = clientName; self.clientKey = clientKey; self.clientNonce = clientNonce
    }
}

public struct PairingCreated: Codable, Sendable, Equatable {
    public var pairingID: String
    public var engineNonce: String
    public var expiresAt: Date
    enum CodingKeys: String, CodingKey { case pairingID = "pairing_id", engineNonce = "engine_nonce", expiresAt = "expires_at" }
    public init(pairingID: String, engineNonce: String, expiresAt: Date) {
        self.pairingID = pairingID; self.engineNonce = engineNonce; self.expiresAt = expiresAt
    }
}

public struct PairingApproved: Codable, Sendable, Equatable {
    public var token: String
    public var clientID: String
    enum CodingKeys: String, CodingKey { case token; case clientID = "client_id" }
    public init(token: String, clientID: String) { self.token = token; self.clientID = clientID }
}
