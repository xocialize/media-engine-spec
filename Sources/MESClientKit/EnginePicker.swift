import Foundation
import MESCore

/// A server the picker may send jobs to: a connection the app can already use (a pairing, or open mode on this Mac).
public struct EngineCandidate: Sendable, Identifiable {
    /// The engine's id (`EngineInfo.id`, TXT `id`).
    public let id: String
    public let name: String
    public let connection: any EngineConnection

    public init(id: String, name: String, connection: any EngineConnection) {
        self.id = id; self.name = name; self.connection = connection
    }

    /// A paired engine, over a pinned TLS connection with its token.
    public init(paired engine: PairedEngine) {
        self.init(id: engine.engineID, name: engine.engineName, connection: HTTPEngineConnection(paired: engine))
    }

    /// The pairings whose engines are on the network now: only paired servers are candidates, and only discovered
    /// ones are reachable. A pairing keeps its own base URL; discovery says only that the engine is there.
    public static func available(pairings: [PairedEngine], discovered: [DiscoveredEngine]) -> [EngineCandidate] {
        let present = Set(discovered.compactMap(\.engineID))
        return pairings.filter { present.contains($0.engineID) }.map(EngineCandidate.init(paired:))
    }
}

/// How the app pins jobs to a server.
public enum EnginePin: Sendable, Equatable {
    case none
    /// Use this server whenever it can run the job; otherwise choose as usual.
    case prefer(String)
    /// Use only this server. A job it can't run fails rather than going elsewhere.
    case only(String)

    var engineID: String? {
        switch self {
        case .none: nil
        case .prefer(let id), .only(let id): id
        }
    }
}

/// A server that can run a job, and what the picker weighed.
public struct EngineChoice: Sendable {
    public let candidate: EngineCandidate
    /// The model that would run: the named one, or the server's default for the operation and tier.
    public let model: String?
    /// The model is in memory there now.
    public let resident: Bool
    /// Jobs ahead of this one there: those waiting (`health.queue_depth`) and the one running, if any.
    public let queueDepth: Int
    public let health: Health
    /// It's the pinned server.
    public let pinned: Bool
}

/// No server can take a job.
public enum EnginePickerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No candidate offers the job. `reasons` says why each was passed over, by engine id.
    case noEngine(operation: String, model: String?, reasons: [String: String])
    /// The job is pinned (`EnginePin.only`) to a server that can't run it.
    case pinnedEngineCannotRun(engineID: String, reason: String)

    public var description: String {
        switch self {
        case .noEngine(let operation, let model, let reasons):
            let what = model.map { "\(operation) with \($0)" } ?? operation
            let why = reasons.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            return "No paired engine offers \(what)" + (why.isEmpty ? "." : " (\(why)).")
        case .pinnedEngineCannotRun(let id, let reason):
            return "The pinned engine \(id) can't run this job: \(reason)"
        }
    }
}

/// Chooses a server for each job when an app knows several (Base §3.1; Gaea G-19: servers on a LAN don't coordinate,
/// so the client chooses).
///
/// For each job it keeps the candidates that offer the operation, the named model (or, with no model named, one that
/// serves the requested tier) and every requested adapter, and whose health isn't `unavailable`. It prefers the pinned
/// server, then the shortest effective queue, where a server without the model in memory counts `loadPenalty` extra
/// jobs for loading it; ties go to the server with the model resident, then to the shorter queue, then by name.
///
///     let picker = EnginePicker(candidates: EngineCandidate.available(pairings: saved, discovered: found))
///     let (engine, job) = try await picker.run(request)
public actor EnginePicker {
    public private(set) var candidates: [EngineCandidate]
    public private(set) var pin: EnginePin
    /// What loading a model is worth, in queued jobs. 0 ranks by queue alone; a large value always prefers residency.
    public var loadPenalty: Int

    public init(candidates: [EngineCandidate] = [], pin: EnginePin = .none, loadPenalty: Int = 2) {
        self.candidates = candidates; self.pin = pin; self.loadPenalty = loadPenalty
    }

    /// Replaces the candidates, e.g. as discovery finds and loses servers.
    public func setCandidates(_ candidates: [EngineCandidate]) { self.candidates = candidates }

    public func setPin(_ pin: EnginePin) { self.pin = pin }

    public func setLoadPenalty(_ jobs: Int) { loadPenalty = max(0, jobs) }

    /// Every candidate that can run `request`, best first, and why each of the others can't.
    public func rank(for request: JobRequest) async -> (choices: [EngineChoice], refused: [String: String]) {
        let pinnedID = pin.engineID
        let assessed = await withTaskGroup(of: (String, Result<EngineChoice, Refusal>).self) { group in
            for candidate in candidates {
                group.addTask {
                    (candidate.id, await Self.assess(candidate, for: request, pinned: candidate.id == pinnedID))
                }
            }
            var all: [(String, Result<EngineChoice, Refusal>)] = []
            for await result in group { all.append(result) }
            return all
        }
        var choices: [EngineChoice] = []
        var refused: [String: String] = [:]
        for (id, result) in assessed {
            switch result {
            case .success(let choice): choices.append(choice)
            case .failure(let refusal): refused[id] = refusal.reason
            }
        }
        let penalty = loadPenalty
        choices.sort { a, b in
            if a.pinned != b.pinned { return a.pinned }
            let costA = a.queueDepth + (a.resident ? 0 : penalty), costB = b.queueDepth + (b.resident ? 0 : penalty)
            if costA != costB { return costA < costB }
            if a.resident != b.resident { return a.resident }
            if a.queueDepth != b.queueDepth { return a.queueDepth < b.queueDepth }
            return (a.candidate.name, a.candidate.id) < (b.candidate.name, b.candidate.id)
        }
        return (choices, refused)
    }

    /// The server `request` should go to.
    public func choose(for request: JobRequest) async throws -> EngineChoice {
        let (choices, refused) = await rank(for: request)
        if case .only(let id) = pin {
            guard let choice = choices.first(where: { $0.candidate.id == id }) else {
                throw EnginePickerError.pinnedEngineCannotRun(engineID: id, reason: refused[id] ?? "it isn't a candidate")
            }
            return choice
        }
        guard let best = choices.first else {
            throw EnginePickerError.noEngine(operation: request.operation, model: request.model, reasons: refused)
        }
        return best
    }

    /// Chooses a server and submits `request` there.
    public func submit(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString) async throws
        -> (engine: EngineCandidate, job: Job) {
        let choice = try await choose(for: request)
        return (choice.candidate, try await choice.candidate.connection.submit(request, idempotencyKey: idempotencyKey))
    }

    /// Chooses a server, submits `request` and follows it until it holds its outputs or ends (`EngineConnection.run`).
    public func run(_ request: JobRequest, idempotencyKey: String? = UUID().uuidString,
                    onEvent: @Sendable (Event) async -> Void = { _ in }) async throws -> (engine: EngineCandidate, job: Job) {
        let choice = try await choose(for: request)
        let job = try await choice.candidate.connection.run(request, idempotencyKey: idempotencyKey, onEvent: onEvent)
        return (choice.candidate, job)
    }

    // MARK: - Assessing one server

    struct Refusal: Error { let reason: String }

    static func assess(_ candidate: EngineCandidate, for request: JobRequest, pinned: Bool) async -> Result<EngineChoice, Refusal> {
        async let operations = candidate.connection.operations()
        async let health = candidate.connection.health()
        let list: OperationsList, status: Health
        do {
            (list, status) = try await (operations, health)
        } catch {
            return .failure(Refusal(reason: "unreachable (\(error))"))
        }
        if status.status == .unavailable { return .failure(Refusal(reason: "unavailable")) }
        guard let descriptor = list.operations.first(where: { $0.operation == request.operation }) else {
            return .failure(Refusal(reason: "doesn't offer \(request.operation)"))
        }
        switch model(for: request, in: descriptor) {
        case .failure(let refusal): return .failure(refusal)
        case .success(let model):
            return .success(EngineChoice(candidate: candidate, model: model,
                                         resident: model.map(status.residentModels.contains) ?? false,
                                         queueDepth: status.queueDepth + (status.running == nil ? 0 : 1), health: status,
                                         pinned: pinned))
        }
    }

    /// The model `request` would run on this descriptor (Base §6 rule 2), or why none can.
    static func model(for request: JobRequest, in descriptor: Descriptor) -> Result<String?, Refusal> {
        let tier = request.params?["quality"]?.stringValue.flatMap(QualityTier.init(rawValue:))
        if let tier, !descriptor.qualityTiers.contains(tier) {
            return .failure(Refusal(reason: "\(request.operation) has no \(tier.rawValue) tier"))
        }
        let adapters = Set(request.adapters?.map(\.id) ?? [])
        func fits(_ offer: ModelOffer) -> Bool {
            (tier.map(offer.qualityTiers.contains) ?? true)
                && adapters.isSubset(of: Set(offer.adapters?.map(\.id) ?? []))
        }
        if let named = request.model {
            guard let offer = descriptor.models.first(where: { $0.id == named }) else {
                return .failure(Refusal(reason: "doesn't offer \(named) for \(request.operation)"))
            }
            guard fits(offer) else {
                return .failure(Refusal(reason: "\(named) doesn't serve this tier or these adapters"))
            }
            return .success(named)
        }
        if descriptor.models.isEmpty && adapters.isEmpty { return .success(nil) }
        // An adapter implies its model, which may be named-only; otherwise the engine's own choice.
        let eligible = descriptor.models.filter { fits($0) && (!adapters.isEmpty || $0.namedOnly != true) }
        guard let pick = eligible.first(where: { $0.isDefault == true }) ?? eligible.first else {
            return .failure(Refusal(reason: adapters.isEmpty ? "no model serves this tier" : "no model takes these adapters"))
        }
        return .success(pick.id)
    }
}
