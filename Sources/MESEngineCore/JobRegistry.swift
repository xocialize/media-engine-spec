import Foundation
import MESCore

/// Owns every job, upload and event (Base §7–§13). One actor, so state transitions are serial; engine runs happen
/// outside it (the actor is reentrant while `run` is awaited).
package actor JobRegistry {
    package struct UploadRecord {
        var upload: Upload
        var owner: String
        var file: URL
    }

    package struct Record {
        var job: Job
        var owner: String
        var clientHost: String?
        var request: JobRequest
        var descriptor: Descriptor
        var model: ModelOffer
        var quality: QualityTier
        var adapters: [AdapterChoice] = []
        var initialEffective: [String: JSONValue]
        var inputs: [String: [RunInput]] = [:]
        var outputFiles: [Int: URL] = [:]
        var events: [Event] = []
        var seq = 0
        var subscribers: [UUID: AsyncStream<Event>.Continuation] = [:]
        var task: Task<Void, Never>?
        var holdsSlot = false
        var cancelled = false
        var confirmed = false
        var lastProgressAt: ContinuousClock.Instant?
        var startedAt: Date?
        var finishedAt: Date?
    }

    package let engine: any MediaEngine
    package let config: EngineConfiguration
    package let spool: Spool
    package private(set) var descriptors: [String: Descriptor] = [:]
    package private(set) var operationsList = OperationsList(operations: [], etag: "\"empty\"")
    private var records: [String: Record] = [:]
    private var uploads: [String: UploadRecord] = [:]
    private var idempotency: [String: (job: String, expires: Date)] = [:]
    private var runningCount = 0
    private var slotWaiters: [(id: String, continuation: CheckedContinuation<Bool, Never>)] = []
    private var sweeper: Task<Void, Never>?
    /// Owner-wide subscriptions (WebSocket `"*"`): every event of every job the owner has, from now on.
    private var ownerSubscribers: [UUID: (owner: String, continuation: AsyncStream<Event>.Continuation)] = [:]
    /// The operator's view (`activityUpdates`): a snapshot after every change, for the engine's own UI.
    private var activitySubscribers: [UUID: AsyncStream<EngineActivity>.Continuation] = [:]
    /// The pinned certificate's fingerprint, in paired mode.
    package var tlsFingerprint: String?

    package init(engine: any MediaEngine, config: EngineConfiguration, spool: Spool) {
        self.engine = engine
        self.config = config
        self.spool = spool
    }

    // MARK: - Lifecycle

    package func start(tlsFingerprint: String? = nil) async {
        self.tlsFingerprint = tlsFingerprint
        await reloadDescriptors()
        guard sweeper == nil else { return }
        let interval = config.sweepInterval
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.sweep(now: Date())
            }
        }
    }

    /// Asks the engine for its descriptors again, e.g. after its operator changed which models it offers. New submits
    /// see the new set, and `GET {path}/operations` gets a new ETag; jobs already accepted keep the model they were given.
    /// Clients subscribed to `"*"` hear `engine.operations_changed` (Base §6 rule 3, §11) when the list changed.
    package func reloadDescriptors() async {
        let list = await engine.descriptors()
        descriptors = Dictionary(list.map { ($0.operation, $0) }, uniquingKeysWith: { first, _ in first })
        let data = (try? MESJSON.encoder.encode(list)) ?? Data()
        let previous = operationsList.etag
        operationsList = OperationsList(operations: list, etag: "\"ops-\(Hashing.sha256(data).prefix(16))\"")
        guard previous != operationsList.etag, previous != "\"empty\"" else { return }
        let event = Event(type: .operationsChanged, job: nil, seq: 0, time: Date(), data: ["etag": .string(operationsList.etag)])
        for sub in ownerSubscribers.values { sub.continuation.yield(event) }
    }

    package func stop() {
        sweeper?.cancel()
        sweeper = nil
        for sub in ownerSubscribers.values { sub.continuation.finish() }
        ownerSubscribers = [:]
        for sub in activitySubscribers.values { sub.finish() }
        activitySubscribers = [:]
        for id in records.keys { records[id]?.task?.cancel() }
    }

    // MARK: - Engine information

    package func engineInfo() -> EngineInfo {
        let profiles = Dictionary(grouping: descriptors.values, by: \.profile)
            .map { EngineInfo.ProfileVersions(id: $0.key, versions: Array(Set($0.value.map(\.profileVersion))).sorted()) }
            .sorted { $0.id < $1.id }
        return EngineInfo(
            id: config.id, name: config.name,
            implementation: .init(name: config.implementationName, version: config.implementationVersion,
                                  url: config.implementationURL),
            baseVersions: EngineConfiguration.baseVersions, profiles: profiles, auth: config.mode,
            tls: tlsFingerprint.map { EngineInfo.TLS(fingerprintSHA256: $0) },
            features: config.features,
            limits: .init(maxUploadBytes: config.maxUploadBytes, maxInlineBytes: config.maxInlineBytes,
                          maxQueuedJobsPerClient: config.maxQueuedJobsPerClient),
            retention: .init(outputsTTLSeconds: config.outputsTTLSeconds, jobRecordTTLSeconds: config.jobRecordTTLSeconds))
    }

    package func health() async -> Health {
        let active = records.values.filter { [.received, .fetching, .waiting].contains($0.job.state) }
        let running = records.values.first { $0.job.state == .running }?.job.id
        return Health(status: .ok, queueDepth: active.count, running: running,
                      residentModels: await engine.residentModels())
    }

    // MARK: - Uploads (§8)

    package func createUpload(owner: String, mediaType: String, file: URL, bytes: Int, sha256: String) -> Upload {
        let id = file.lastPathComponent
        let upload = Upload(uploadID: id, mediaType: mediaType, bytes: bytes, sha256: sha256,
                            expiresAt: Date().addingTimeInterval(TimeInterval(config.uploadTTLSeconds)))
        uploads[id] = UploadRecord(upload: upload, owner: owner, file: file)
        return upload
    }

    // MARK: - Submit (§7.1)

    package func submit(_ request: JobRequest, owner: String, clientHost: String?, idempotencyKey: String?) throws -> Job {
        if let key = idempotencyKey, let hit = idempotency["\(owner)\u{0}\(key)"], hit.expires > Date(),
           let record = records[hit.job], record.owner == owner {
            return record.job
        }
        guard let descriptor = descriptors[request.operation] else {
            throw MESError(.unknownOperation, "No operation \(request.operation) on this engine.", param: "operation")
        }
        let active = records.values.filter { $0.owner == owner && [.received, .fetching, .waiting, .running].contains($0.job.state) }
        if active.count >= config.maxQueuedJobsPerClient {
            throw MESError(.busy, "At most \(config.maxQueuedJobsPerClient) jobs may be queued per client.")
        }
        try validateInputs(request, descriptor: descriptor, owner: owner)
        try validateParams(request, descriptor: descriptor)
        try validateExtensions(request, descriptor: descriptor)
        try engine.validate(request, descriptor: descriptor)
        let (model, quality) = try chooseModel(request, descriptor: descriptor)
        let adapters = try chooseAdapters(request, model: model)

        let now = Date()
        let id = IDs.make("job_")
        try spool.makeJobDirectories(id)
        var effective = request.params ?? [:]
        effective[ImageProfile.Param.quality] = .string(quality.rawValue)
        let job = Job(id: id, operation: request.operation, clientRef: request.clientRef, state: .received,
                      warnings: [], retention: .init(recordExpiresAt: now.addingTimeInterval(TimeInterval(config.jobRecordTTLSeconds))),
                      createdAt: now, updatedAt: now)
        records[id] = Record(job: job, owner: owner, clientHost: clientHost, request: request, descriptor: descriptor,
                             model: model, quality: quality, adapters: adapters, initialEffective: effective)
        // Uploads are single-use: claimed now, so a second job naming one is refused.
        for value in (request.inputs ?? [:]).values.flatMap(\.values) {
            if case .upload(let uid) = value { uploads[uid]?.owner = "\u{0}claimed:\(id)" }
        }
        if let key = idempotencyKey { idempotency["\(owner)\u{0}\(key)"] = (id, now.addingTimeInterval(86_400)) }
        emit(id, .state, ["state": "received"])
        records[id]?.task = Task { [weak self] in await self?.execute(id) }
        return records[id]!.job
    }

    private func validateInputs(_ request: JobRequest, descriptor: Descriptor, owner: String) throws {
        let given = request.inputs ?? [:]
        let specs = Dictionary(descriptor.inputs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for name in given.keys where specs[name] == nil {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) has no input '\(name)'.", param: name)
        }
        for spec in descriptor.inputs {
            guard let input = given[spec.name] else {
                if spec.required { throw MESError(.invalidRequest, "Input '\(spec.name)' is required.", param: spec.name) }
                continue
            }
            switch (spec.kind, input) {
            case (.text, .text): continue
            case (.text, _): throw MESError(.inputInvalid, "Input '\(spec.name)' must be text.", param: spec.name)
            case (_, .text): throw MESError(.inputInvalid, "Input '\(spec.name)' must be a \(spec.kind.rawValue), not text.", param: spec.name)
            default: break
            }
            let values = input.values
            if let max = spec.max, values.count > max {
                throw MESError(.outOfLimits, "Input '\(spec.name)' takes at most \(max).", param: spec.name)
            }
            if let min = spec.min, values.count < min {
                throw MESError(.invalidRequest, "Input '\(spec.name)' needs at least \(min).", param: spec.name)
            }
            for value in values {
                let mediaType: String?
                switch value {
                case .data:
                    guard spec.kind == .data else {
                        throw MESError(.inputInvalid, "Input '\(spec.name)' is media, not data.", param: spec.name)
                    }
                    mediaType = nil
                case .inline(let mt, let data):
                    if data.count > config.maxInlineBytes {
                        throw MESError(.tooLarge, "Inline input '\(spec.name)' exceeds \(config.maxInlineBytes) bytes; upload it.", param: spec.name)
                    }
                    mediaType = mt
                case .upload(let uid):
                    guard let record = uploads[uid], record.owner == owner else {
                        throw MESError(.inputInvalid, "Upload \(uid) is unknown, expired or already used.", param: spec.name)
                    }
                    mediaType = record.upload.mediaType
                case .grant(let grant):
                    guard config.grants else {
                        throw MESError(.unsupportedParameter, "This engine doesn't fetch grants; upload the input.", param: spec.name)
                    }
                    mediaType = grant.mediaType
                }
                if spec.kind == .data, mediaType != nil {
                    throw MESError(.inputInvalid, "Input '\(spec.name)' is data: send {\"data\": …}.", param: spec.name)
                }
                if let mt = mediaType, let accepted = spec.mediaTypes, !accepted.contains(mt) {
                    throw MESError(.unsupportedMediaType, "Input '\(spec.name)' accepts \(accepted.joined(separator: ", ")), not \(mt).",
                                   param: spec.name)
                }
            }
        }
    }

    private func validateParams(_ request: JobRequest, descriptor: Descriptor) throws {
        let issues = SchemaValidator().validate(.object(request.params ?? [:]), against: descriptor.params)
        guard let first = issues.first else { return }
        if let range = first.message.range(of: "unexpected property '") {
            let name = first.message[range.upperBound...].dropLast()
            throw MESError(.unsupportedParameter, "\(descriptor.operation) has no parameter '\(name)'.", param: String(name))
        }
        let param = first.path.split(separator: ".").dropFirst().first.map(String.init)
        // An `output` the engine doesn't offer (a media type, a bit depth) is a feature it can't honour, not a limit
        // (Image §1.2): 422 unsupported_parameter.
        if param == "output" {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) can't produce that output: \(first.path): \(first.message)",
                           param: "output")
        }
        throw MESError(.outOfLimits, "\(first.path): \(first.message)", param: param)
    }

    private func validateExtensions(_ request: JobRequest, descriptor: Descriptor) throws {
        let declared = Dictionary((descriptor.extensions ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, value) in request.extensions ?? [:] {
            guard let ext = declared[name] else {
                throw MESError(.unsupportedParameter, "Unknown extension \(name).", param: name)
            }
            if let issue = SchemaValidator().validate(value, against: ext.schema).first {
                throw MESError(.outOfLimits, "Extension \(name): \(issue)", param: name)
            }
        }
    }

    /// Model choice (Base §6 rule 2, §6.3, §10.3): a named model must exist, satisfy the policy and list every requested
    /// adapter; otherwise the default offer for the requested quality tier that satisfies the policy and lists them.
    private func chooseModel(_ request: JobRequest, descriptor: Descriptor) throws -> (ModelOffer, QualityTier) {
        var quality = QualityTier.standard
        if let raw = request.params?[ImageProfile.Param.quality]?.stringValue {
            guard let q = QualityTier(rawValue: raw) else {
                throw MESError(.unsupportedParameter, "Unknown quality tier \(raw).", param: "quality")
            }
            quality = q
        } else if !descriptor.qualityTiers.contains(.standard), let first = descriptor.qualityTiers.first {
            quality = first
        }
        guard descriptor.qualityTiers.contains(quality) else {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) offers \(descriptor.qualityTiers.map(\.rawValue).joined(separator: ", ")).",
                           param: "quality")
        }
        let policy = request.policy ?? Policy()
        func satisfies(_ m: ModelOffer) -> Bool { policy.allows(m) }
        // Adapters (§6.3): each listed at most once, by some offer of this operation; an adapter implies its model.
        let wanted = (request.adapters ?? []).map(\.id)
        if Set(wanted).count != wanted.count {
            throw MESError(.invalidRequest, "Each adapter may be asked for once.", param: "adapters")
        }
        if let unknown = wanted.first(where: { id in !descriptor.models.contains { $0.adapter(id) != nil } }) {
            throw MESError(.unsupportedParameter, "\(descriptor.operation) offers no adapter \(unknown).", param: "adapters")
        }
        func fits(_ m: ModelOffer) -> Bool { wanted.allSatisfy { m.adapter($0) != nil } }
        if let named = request.model {
            guard let model = descriptor.models.first(where: { $0.id == named }) else {
                throw MESError(.modelUnavailable, "\(descriptor.operation) offers no model \(named).", param: "model")
            }
            guard satisfies(model) else {
                throw MESError(.policyUnmet, "Model \(named) doesn't satisfy the request's policy.",
                               reason: "\(model.id): \(model.license.spdx)", param: "model")
            }
            if let misfit = wanted.first(where: { model.adapter($0) == nil }) {
                throw MESError(.unsupportedParameter, "Model \(named) doesn't take the adapter \(misfit).", param: "adapters")
            }
            return (model, model.qualityTiers.contains(quality) ? quality : (model.qualityTiers.first ?? quality))
        }
        // Named-only offers (research, opt-in) never run by default (Base §6 rule 2), adapters or not.
        let forTier = descriptor.models.filter { $0.qualityTiers.contains(quality) && $0.namedOnly != true && fits($0) }
        let allowed = forTier.filter(satisfies)
        guard let model = allowed.first(where: { $0.isDefault == true }) ?? allowed.first else {
            if forTier.isEmpty, !wanted.isEmpty {
                throw MESError(.unsupportedParameter, "No model at the \(quality.rawValue) tier takes \(wanted.joined(separator: " with ")) "
                               + "without being named.", param: "adapters")
            }
            if forTier.isEmpty {
                throw MESError(.unsupportedParameter, "No model offers the \(quality.rawValue) tier.", param: "quality")
            }
            throw MESError(.policyUnmet, "No model for \(descriptor.operation) at \(quality.rawValue) satisfies the policy.",
                           reason: forTier.map { "\($0.id): \($0.license.spdx)" }.joined(separator: "; "))
        }
        if let refined = engine.defaultModel(for: request, descriptor: descriptor, kitChoice: model, candidates: allowed),
           allowed.contains(where: { $0.id == refined.id }) {
            return (refined, quality)
        }
        return (model, quality)
    }

    /// The requested adapters on the chosen model (§6.3, §10.3): within its `max_adapters`, each strength within its
    /// range (default when absent), each licence allowed by the policy.
    private func chooseAdapters(_ request: JobRequest, model: ModelOffer) throws -> [AdapterChoice] {
        let wanted = request.adapters ?? []
        guard !wanted.isEmpty else { return [] }
        if wanted.count > model.adapterLimit {
            throw MESError(.outOfLimits, "\(model.id) takes at most \(model.adapterLimit) adapter\(model.adapterLimit == 1 ? "" : "s") per request.",
                           param: "adapters")
        }
        let policy = request.policy ?? Policy()
        return try wanted.map { a in
            guard let offer = model.adapter(a.id) else {
                throw MESError(.unsupportedParameter, "Model \(model.id) doesn't take the adapter \(a.id).", param: "adapters")
            }
            let strength = a.strength ?? offer.strength.defaultValue
            guard offer.strength.contains(strength) else {
                throw MESError(.outOfLimits, "Adapter \(a.id) takes a strength from \(offer.strength.min) to \(offer.strength.max).",
                               param: "adapters")
            }
            guard policy.allows(offer.license) else {
                throw MESError(.policyUnmet, "Adapter \(a.id) doesn't satisfy the request's policy.",
                               reason: "\(a.id): \(offer.license.spdx)", param: "adapters")
            }
            return AdapterChoice(offer: offer, strength: strength)
        }
    }

    // MARK: - Execution

    private func execute(_ id: String) async {
        do {
            try await materializeInputs(id)
        } catch {
            if records[id]?.cancelled == true { return }
            fail(id, error)
            return
        }
        guard records[id]?.cancelled == false else { return }
        setState(id, .waiting, progress: JobProgress(stage: .waiting))
        guard await acquireSlot(id) else { return }
        guard var record = records[id], !record.cancelled else { releaseSlot(); return }
        record.holdsSlot = true
        record.startedAt = Date()
        record.job.state = .running
        record.job.plan = Plan(model: record.model.ref, effective: record.initialEffective,
                               remoteProvider: record.model.remoteProvider)
        record.job.progress = JobProgress(stage: .running)
        record.job.updatedAt = Date()
        records[id] = record
        emit(id, .state, ["state": "running"])
        emit(id, .plan, (try? JSONValue(encoding: record.job.plan!)) ?? .null)

        let context = RunContext(
            jobID: id, operation: record.request.operation, descriptor: record.descriptor, model: record.model,
            adapters: record.adapters, quality: record.quality, params: record.request.params ?? [:], extensions: record.request.extensions ?? [:],
            inputs: record.inputs, policy: record.request.policy ?? Policy(), outputDirectory: spool.outputsDirectory(id),
            reporter: RunReporter(
                progress: { [weak self] p in await self?.reportProgress(id, p) },
                warning: { [weak self] w in await self?.reportWarning(id, w) },
                preview: { [weak self] d, mt in await self?.reportPreview(id, d, mt) }))
        let startedAt = Date()
        do {
            let output = try await engine.run(context)
            if records[id]?.cancelled ?? true { cleanUpCancelled(id); return }
            try finishSuccess(id, output, startedAt: startedAt)
        } catch {
            if records[id]?.cancelled ?? true { cleanUpCancelled(id); return }
            fail(id, error)
        }
    }

    private func materializeInputs(_ id: String) async throws {
        guard let record = records[id] else { return }
        let dir = spool.inputsDirectory(id)
        let hasGrants = (record.request.inputs ?? [:]).values.flatMap(\.values).contains { if case .grant = $0 { true } else { false } }
        if hasGrants { setState(id, .fetching, progress: JobProgress(stage: .fetching)) }
        var resolved: [String: [RunInput]] = [:]
        for (name, input) in (record.request.inputs ?? [:]).sorted(by: { $0.key < $1.key }) {
            if case .text(let s) = input { resolved[name] = [.text(s)]; continue }
            var list: [RunInput] = []
            for (i, value) in input.values.enumerated() {
                switch value {
                case .data(let v):
                    list.append(.data(v))
                case .inline(let mt, let data):
                    let file = dir.appendingPathComponent("\(name)-\(i).\(MediaTypes.fileExtension(mt))")
                    try data.write(to: file)
                    list.append(.file(file, mediaType: mt))
                case .upload(let uid):
                    guard let up = uploads.removeValue(forKey: uid) else {
                        throw MESError(.inputInvalid, "Upload \(uid) is no longer available.", param: name)
                    }
                    let file = dir.appendingPathComponent("\(name)-\(i).\(MediaTypes.fileExtension(up.upload.mediaType))")
                    try FileManager.default.moveItem(at: up.file, to: file)
                    list.append(.file(file, mediaType: up.upload.mediaType))
                case .grant(let grant):
                    let file = dir.appendingPathComponent("\(name)-\(i).\(MediaTypes.fileExtension(grant.mediaType))")
                    try await GrantFetcher.fetch(grant, to: file, clientHost: record.clientHost, maxBytes: config.maxUploadBytes)
                    list.append(.file(file, mediaType: grant.mediaType))
                }
            }
            resolved[name] = list
        }
        records[id]?.inputs = resolved
    }

    private func finishSuccess(_ id: String, _ output: RunOutput, startedAt: Date) throws {
        guard var record = records[id] else { return }
        spool.deleteInputs(id)                                   // §13 rule 1
        record.inputs = [:]
        let outDir = spool.outputsDirectory(id)
        let names = Set(record.descriptor.outputs.map(\.name))
        var outputs: [Output] = []
        for (index, produced) in output.outputs.enumerated() {
            guard names.contains(produced.name) else {
                throw MESError(.engineError, "The engine produced an undeclared output '\(produced.name)'.")
            }
            var file = outDir.appendingPathComponent("\(index).\(MediaTypes.fileExtension(produced.mediaType))")
            if let src = produced.file {
                if src.standardizedFileURL != file.standardizedFileURL {
                    try? FileManager.default.removeItem(at: file)
                    try FileManager.default.moveItem(at: src, to: file)
                }
            } else if let value = produced.value {
                try MESJSON.encoder.encode(value).write(to: file)
            } else {
                throw MESError(.engineError, "Output \(produced.name) has neither a file nor a value.")
            }
            file = file.standardizedFileURL
            let (sha, bytes) = try Hashing.sha256(of: file)
            record.outputFiles[index] = file
            outputs.append(Output(index: index, name: produced.name, kind: produced.kind, mediaType: produced.mediaType,
                                  bytes: bytes, sha256: sha, href: "\(config.basePath)/jobs/\(id)/outputs/\(index)",
                                  width: produced.width, height: produced.height, durationSeconds: produced.durationSeconds,
                                  fps: produced.fps, value: bytes <= 65_536 ? produced.value : nil))
        }
        guard !outputs.isEmpty else { throw MESError(.engineError, "The engine produced no outputs.") }
        var effective = record.initialEffective
        for (k, v) in output.effective { effective[k] = v }
        if let seed = output.seed { effective[ImageProfile.Param.seed] = .number(Double(seed)) }
        for w in output.warnings { record.job.warnings.append(w) }
        let now = Date()
        let ttl = record.descriptor.retention?.outputsTTLSeconds ?? config.outputsTTLSeconds
        record.job.plan?.effective = effective
        record.job.result = JobResult(
            outputs: outputs, effective: effective,
            provenance: Provenance(
                engine: .init(id: config.id, name: config.name, implementation: config.implementationName,
                              version: config.implementationVersion),
                operation: record.request.operation, profileVersion: record.descriptor.profileVersion,
                model: ModelRef(id: record.model.id, title: record.model.title, revision: output.revisions[record.model.id],
                                license: record.model.license),
                adapters: record.adapters.isEmpty ? nil : record.adapters.map { a in
                    var ref = a.offer.ref(strength: a.strength)
                    ref.revision = output.revisions[a.id]
                    return ref
                },
                helpers: output.helpers.isEmpty ? nil : output.helpers,
                remoteProvider: record.model.remoteProvider, seed: output.seed,
                timings: .init(receivedAt: record.job.createdAt, startedAt: startedAt, finishedAt: now,
                               queueMs: Int(startedAt.timeIntervalSince(record.job.createdAt) * 1000),
                               runMs: Int(now.timeIntervalSince(startedAt) * 1000))))
        record.job.state = .holding
        record.job.outcome = .succeeded
        record.job.progress = JobProgress(stage: .finishing, fraction: 1)
        let outputsExpire = now.addingTimeInterval(TimeInterval(ttl))
        record.job.retention.outputsExpireAt = outputsExpire
        record.job.retention.recordExpiresAt = max(record.job.retention.recordExpiresAt, outputsExpire.addingTimeInterval(60))
        record.job.updatedAt = now
        records[id] = record
        for w in output.warnings { emit(id, .warning, (try? JSONValue(encoding: w)) ?? .null) }
        emit(id, .outputReady, ["outputs": (try? JSONValue(encoding: outputs)) ?? .null])
        emit(id, .state, ["state": "holding", "outcome": "succeeded"])
        releaseSlotIfHeld(id)
    }

    private func fail(_ id: String, _ error: Error) {
        guard var record = records[id] else { return }
        var mesError = (error as? MESError) ?? MESError(.engineError, "\(error)")
        mesError.job = id
        spool.deleteJob(id)                                      // §13 rules 1 and 2
        record.inputs = [:]
        record.outputFiles = [:]
        record.job.state = .purged
        record.job.outcome = .failed
        record.job.error = mesError
        record.job.updatedAt = Date()
        records[id] = record
        emit(id, .state, ["state": "purged", "outcome": "failed"])
        emit(id, .ended, ["outcome": "failed", "error": (try? JSONValue(encoding: mesError)) ?? .null])
        finishSubscribers(id)
        releaseSlotIfHeld(id)
    }

    private func cleanUpCancelled(_ id: String) {
        spool.deleteJob(id)
        releaseSlotIfHeld(id)
    }

    // MARK: - Slots

    private func acquireSlot(_ id: String) async -> Bool {
        if runningCount < config.concurrency {
            runningCount += 1
            return true
        }
        return await withCheckedContinuation { continuation in slotWaiters.append((id, continuation)) }
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()
            next.continuation.resume(returning: true)            // the slot passes on; the count is unchanged
        } else {
            runningCount = max(0, runningCount - 1)
        }
    }

    private func releaseSlotIfHeld(_ id: String) {
        guard records[id]?.holdsSlot == true else { return }
        records[id]?.holdsSlot = false
        releaseSlot()
    }

    // MARK: - Client actions (§7.3)

    package func job(_ id: String, owner: String) throws -> Job { try record(id, owner: owner).job }

    package func list(owner: String, state: JobState?) -> [Job] {
        records.values.filter { $0.owner == owner && (state == nil || $0.job.state == state) }
            .map(\.job).sorted { $0.createdAt < $1.createdAt }
    }

    /// Long-poll (Base §7.3): while the job is active, returns when its state changes or `seconds` pass; a job already
    /// holding or purged answers at once, so a client that polls just after completion doesn't wait for the next
    /// change (which, for a held job, is its expiry).
    package func waitForChange(_ id: String, owner: String, seconds: Int) async throws -> Job {
        let current = try record(id, owner: owner)
        guard seconds > 0, [.received, .fetching, .waiting, .running].contains(current.job.state) else { return current.job }
        let stream = try subscribe(id, owner: owner, after: current.seq)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in stream where event.type == .state || event.type == .ended { return }
            }
            // A child task, so cancelAll() ends it: awaiting an unstructured Task here kept every wait open to its deadline.
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
        return try record(id, owner: owner).job
    }

    package func release(_ id: String, owner: String) throws -> Job {
        var record = try record(id, owner: owner)
        switch record.job.state {
        case .purged:
            return record.job
        case .holding:
            discardOutputs(id, outcome: nil)
        case .received, .fetching, .waiting, .running:
            record.cancelled = true
            record.task?.cancel()
            records[id] = record
            if let i = slotWaiters.firstIndex(where: { $0.id == id }) {
                slotWaiters.remove(at: i).continuation.resume(returning: false)
            }
            if record.job.state != .running { spool.deleteJob(id) }   // a running job cleans up when run returns
            records[id]?.job.state = .purged
            records[id]?.job.outcome = .cancelled
            records[id]?.job.updatedAt = Date()
            emit(id, .state, ["state": "purged", "outcome": "cancelled"])
            emit(id, .ended, ["outcome": "cancelled"])
            finishSubscribers(id)
        }
        return records[id]!.job
    }

    package func confirm(_ id: String, owner: String) throws -> Job {
        let record = try record(id, owner: owner)
        switch record.job.state {
        case .holding:
            records[id]?.confirmed = true
            discardOutputs(id, outcome: nil)
            return records[id]!.job
        case .purged where record.confirmed:
            throw MESError(.alreadyConfirmed, "Job \(id) was already confirmed.", job: id)
        case .purged:
            throw MESError(.gone, "Job \(id)'s outputs are gone (\(record.job.outcome?.rawValue ?? "purged")).", job: id)
        default:
            throw MESError(.conflict, "Job \(id) has no outputs yet (\(record.job.state.rawValue)).", job: id)
        }
    }

    package func output(_ id: String, index: Int, owner: String) throws -> (URL, Output) {
        let record = try record(id, owner: owner)
        switch record.job.state {
        case .holding:
            guard let output = record.job.result?.outputs.first(where: { $0.index == index }),
                  let file = record.outputFiles[index] else {
                throw MESError(.notFound, "Job \(id) has no output \(index).", job: id)
            }
            return (file, output)
        case .purged:
            throw MESError(.gone, "Job \(id)'s outputs are gone.", job: id)
        default:
            throw MESError(.conflict, "Job \(id) has no outputs yet.", job: id)
        }
    }

    /// Events after `seq`, then live ones; the stream finishes after `job.ended`.
    package func subscribe(_ id: String, owner: String, after seq: Int) throws -> AsyncStream<Event> {
        let record = try record(id, owner: owner)
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(1024))
        for event in record.events where event.seq > seq { continuation.yield(event) }
        if record.events.contains(where: { $0.type == .ended }) {
            continuation.finish()
        } else {
            let token = UUID()
            records[id]?.subscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id, token) } }
        }
        return stream
    }

    private func unsubscribe(_ id: String, _ token: UUID) { records[id]?.subscribers[token] = nil }

    /// Every future event of the owner's jobs (Base §11, WebSocket `"*"`).
    package func subscribeAll(owner: String) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(4096))
        let token = UUID()
        ownerSubscribers[token] = (owner, continuation)
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribeAll(token) } }
        return stream
    }

    private func unsubscribeAll(_ token: UUID) { ownerSubscribers[token] = nil }

    // MARK: - The operator's view (ENG-9)

    /// Every job from every client, active ones in slot order.
    package func activity() -> EngineActivity {
        let waiting = slotWaiters.map(\.id)
        func activity(_ r: Record) -> JobActivity {
            JobActivity(id: r.job.id, operation: r.job.operation, client: r.owner, clientHost: r.clientHost,
                        model: r.model.ref, quality: r.quality, state: r.job.state, outcome: r.job.outcome,
                        progress: r.job.progress, warnings: r.job.warnings, error: r.job.error?.message,
                        summary: JobActivity.summary(of: r.request), createdAt: r.job.createdAt, startedAt: r.startedAt,
                        finishedAt: r.finishedAt, queuePosition: waiting.firstIndex(of: r.job.id).map { $0 + 1 })
        }
        let all = records.values.map(activity)
        let active = all.filter { $0.outcome == nil }.sorted { a, b in
            func rank(_ j: JobActivity) -> (Int, Int, Date) {
                switch j.state {
                case .running: (0, 0, j.createdAt)
                case .waiting: (1, j.queuePosition ?? Int.max, j.createdAt)
                default: (2, 0, j.createdAt)
                }
            }
            return rank(a) < rank(b)
        }
        let finished = all.filter { $0.outcome != nil }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            .prefix(EngineActivity.finishedLimit)
        return EngineActivity(jobs: active + finished, concurrency: config.concurrency)
    }

    /// A snapshot now, then one after every change (progress at most every `minProgressInterval`).
    package func activityUpdates() -> AsyncStream<EngineActivity> {
        let (stream, continuation) = AsyncStream<EngineActivity>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        activitySubscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribeActivity(token) } }
        continuation.yield(activity())
        return stream
    }

    private func unsubscribeActivity(_ token: UUID) { activitySubscribers[token] = nil }

    private func publishActivity() {
        guard !activitySubscribers.isEmpty else { return }
        let snapshot = activity()
        for continuation in activitySubscribers.values { continuation.yield(snapshot) }
    }

    /// Cancels any client's job, as its owner releasing it would (Base §7.3): a waiting job leaves the queue, a running
    /// one is cancelled at the model, a held one's outputs are discarded.
    package func cancelAsOperator(_ id: String) throws -> Job {
        guard let owner = records[id]?.owner else { throw MESError(.notFound, "No job \(id).", job: id) }
        return try release(id, owner: owner)
    }

    // MARK: - Retention (§13)

    package func sweep(now: Date) {
        for (id, record) in records {
            if record.job.state == .holding, let expires = record.job.retention.outputsExpireAt, expires <= now {
                discardOutputs(id, outcome: .expired)
            } else if record.job.state == .purged, record.job.retention.recordExpiresAt <= now {
                finishSubscribers(id)
                records[id] = nil
                publishActivity()
            }
        }
        for (uid, up) in uploads where up.upload.expiresAt <= now {
            try? FileManager.default.removeItem(at: up.file)
            uploads[uid] = nil
        }
        idempotency = idempotency.filter { $0.value.expires > now }
    }

    private func discardOutputs(_ id: String, outcome: Outcome?) {
        spool.deleteJob(id)                                      // §13 rule 2
        records[id]?.outputFiles = [:]
        records[id]?.job.state = .purged
        if let outcome { records[id]?.job.outcome = outcome }
        records[id]?.job.retention.outputsExpireAt = nil
        records[id]?.job.updatedAt = Date()
        let final = records[id]?.job.outcome?.rawValue ?? "succeeded"
        emit(id, .state, ["state": "purged", "outcome": .string(final)])
        emit(id, .ended, ["outcome": .string(final)])
        finishSubscribers(id)
    }

    // MARK: - Events (§11)

    private func setState(_ id: String, _ state: JobState, progress: JobProgress? = nil) {
        records[id]?.job.state = state
        if let progress { records[id]?.job.progress = progress }
        records[id]?.job.updatedAt = Date()
        emit(id, .state, ["state": .string(state.rawValue)])
    }

    private func reportProgress(_ id: String, _ progress: JobProgress) {
        guard let record = records[id], record.job.state == .running, !record.cancelled else { return }
        let now = ContinuousClock.now
        let final = progress.fraction == 1 || (progress.step != nil && progress.step == progress.steps)
        if let last = record.lastProgressAt, now - last < config.minProgressInterval, !final { return }
        records[id]?.lastProgressAt = now
        records[id]?.job.progress = progress
        emit(id, .progress, (try? JSONValue(encoding: progress)) ?? .null)
    }

    private func reportWarning(_ id: String, _ warning: Warning) {
        records[id]?.job.warnings.append(warning)
        emit(id, .warning, (try? JSONValue(encoding: warning)) ?? .null)
    }

    private func reportPreview(_ id: String, _ data: Data, _ mediaType: String) {
        guard data.count <= 262_144 else { return }
        emit(id, .preview, ["media_type": .string(mediaType), "data": .string(data.base64EncodedString())])
    }

    private func emit(_ id: String, _ type: EventType, _ data: JSONValue) {
        guard var record = records[id] else { return }
        record.seq += 1
        if record.job.outcome != nil, record.finishedAt == nil { record.finishedAt = Date() }
        let event = Event(type: type, job: id, clientRef: record.job.clientRef, seq: record.seq, time: Date(), data: data)
        record.events.append(event)
        records[id] = record
        for continuation in record.subscribers.values { continuation.yield(event) }
        for sub in ownerSubscribers.values where sub.owner == record.owner { sub.continuation.yield(event) }
        if type != .preview { publishActivity() }
    }

    private func finishSubscribers(_ id: String) {
        guard let subs = records[id]?.subscribers else { return }
        records[id]?.subscribers = [:]
        for continuation in subs.values { continuation.finish() }
    }

    private func record(_ id: String, owner: String) throws -> Record {
        guard let record = records[id], record.owner == owner else {
            throw MESError(.notFound, "No job \(id).", job: id)
        }
        return record
    }
}
