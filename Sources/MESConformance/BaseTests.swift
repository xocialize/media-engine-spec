import Foundation
import MESClientKit
import MESCore

/// The Base 0.1 tests (BASE-nnn), in catalogue order.
enum BaseTests {
    static let paired: @Sendable (Probe) -> String? = { $0.info.auth == .paired ? nil : "open mode" }
    static func feature(_ f: Feature) -> @Sendable (Probe) -> String? { { $0.has(f) ? nil : "the engine doesn't claim `\(f.rawValue)`" } }
    static let needsOperation: @Sendable (Probe) -> String? = {
        $0.baseOperation == nil ? "no operation the suite can drive with text and image inputs" : nil
    }
    static let offersAdapters: @Sendable (Probe) -> String? = {
        $0.operations.contains { d in d.models.contains { !($0.adapters ?? []).isEmpty } } ? nil : "no model offer lists adapters"
    }

    /// An operation the suite can drive, an offer on it (preferring one that isn't `named_only`) and a `plain` adapter
    /// the offer takes, for BASE-029.
    static func plainAdapter(_ p: Probe) -> (Descriptor, JobRequest, ModelOffer, AdapterOffer)? {
        for d in p.operations {
            guard let request = p.minimalRequest(d) else { continue }
            let offers = d.models.sorted { ($0.namedOnly == true ? 1 : 0) < ($1.namedOnly == true ? 1 : 0) }
            for m in offers {
                if let a = m.adapters?.first(where: { $0.kind == .plain }) {
                    return (d, request, m, a)
                }
            }
        }
        return nil
    }

    static let all: [ConformanceTest] = [
        // MARK: Handshake, transport, versioning (§2–§4)
        ConformanceTest("BASE-001", "Engine information validates; uploads and SSE are claimed; Base 0.1 is offered", spec: "§4") { p in
            try p.schemas.require(p.infoBody, "base/engine-info.schema.json", "GET engine")
            try check(p.info.baseVersions.contains("0.1"), "base_versions \(p.info.baseVersions) lacks 0.1")
            try check(p.has(.uploads) && p.has(.sse), "uploads and sse are REQUIRED features; claimed: \(p.info.features.map(\.rawValue))")
            if p.info.auth == .paired {
                try check(p.has(.pairing), "a paired engine MUST support pairing")
                try check(p.info.tls?.fingerprintSHA256.count == 64, "a paired engine reports tls.fingerprint_sha256")
            }
            try check(p.info.retention.outputsTTLSeconds <= 86_400, "outputs_ttl_s \(p.info.retention.outputsTTLSeconds) exceeds 86400 (§13 rule 2)")
            return nil
        },
        ConformanceTest("BASE-002", "Responses echo MES-Version and carry MES-Request-Id, on success and on error", spec: "§2, §3.2") { p in
            let ok = try await p.wire.send("GET", "health")
            let bad = try await p.wire.send("GET", "jobs/job_conformance_missing")
            for (reply, what) in [(ok, "GET health"), (bad, "an error response")] {
                try check(reply.header("MES-Version") == "0.1", "\(what) has MES-Version \(reply.header("MES-Version") ?? "missing"), not 0.1 (§2 rule 4)")
            }
            let note = ok.header("MES-Request-Id") == nil || bad.header("MES-Request-Id") == nil
                ? Note("Some responses lack MES-Request-Id (SHOULD, §3.2).") : nil
            return note
        },
        ConformanceTest("BASE-003", "An unsupported MES-Version is refused with 400 unsupported_version", spec: "§2") { p in
            let reply = try await p.wire.send("GET", "operations", headers: ["MES-Version": "9.9"])
            try expect(reply, 400, code: "unsupported_version", "MES-Version: 9.9", schemas: p.schemas)
            try check(reply.json?["error"]?["supported_versions"]?.arrayValue?.contains("0.1") == true,
                      "the error lists supported_versions including 0.1")
            return nil
        },
        ConformanceTest("BASE-004", "A request from a browser origin outside the allowlist is refused with 403 origin_not_allowed", spec: "§3.2") { p in
            let reply = try await p.wire.send("GET", "engine", headers: ["Origin": "https://conformance.invalid"])
            try expect(reply, 403, code: "origin_not_allowed", "Origin: https://conformance.invalid", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-005", "Paired mode: the handshake needs no token; everything else answers 401 without one", spec: "§3.3",
                        applies: paired) { p in
            let anonymous = Wire(baseURL: p.wire.baseURL, pinned: p.wire.presentedFingerprint)
            try expect(try await anonymous.send("GET", "engine"), 200, "GET engine without a token", schemas: p.schemas)
            for path in ["operations", "health", "jobs"] {
                try expect(try await anonymous.send("GET", path), 401, code: "unauthorized", "GET \(path) without a token", schemas: p.schemas)
            }
            let forged = Wire(baseURL: p.wire.baseURL, token: "mes_tok_conformance-not-a-token", pinned: p.wire.presentedFingerprint)
            try expect(try await forged.send("GET", "operations"), 401, code: "unauthorized", "GET operations with a forged token", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-006", "Paired mode: the certificate served is the one tls.fingerprint_sha256 names", spec: "§3.3, §5",
                        applies: paired) { p in
            _ = try await p.wire.send("GET", "engine")
            let presented = p.wire.presentedFingerprint.map(Hex.string)
            try check(presented != nil && presented == p.info.tls?.fingerprintSHA256,
                      "served \(presented ?? "no certificate"), advertised \(p.info.tls?.fingerprintSHA256 ?? "none")")
            return nil
        },

        // MARK: Descriptors (§6)
        ConformanceTest("BASE-010", "Descriptors validate, name their profile, and offer at least one licensed model", spec: "§6, §10.2") { p in
            let reply = try await p.wire.send("GET", "operations")
            try p.schemas.require(reply.body, "base/operations-list.schema.json", "GET operations")
            try check(!p.operations.isEmpty, "the engine offers no operations")
            let profiles = Set(p.info.profiles.map(\.id))
            for d in p.operations {
                try p.schemas.require(try JSONValue(encoding: d), "base/descriptor.schema.json", d.operation)
                try check(profiles.contains(d.profile), "\(d.operation) names profile \(d.profile), which engine info doesn't list")
                try check(!d.models.isEmpty, "\(d.operation) offers no model")
                try check(d.models.filter { $0.isDefault == true }.count <= 1, "\(d.operation) has several default models")
                try check(!d.models.contains { $0.isDefault == true && $0.namedOnly == true },
                          "\(d.operation) has a model that is both default and named_only (§6 rule 2)")
                try check(d.params["type"]?.stringValue == "object", "\(d.operation)'s params isn't an object schema")
            }
            return nil
        },
        ConformanceTest("BASE-013", "Adapter offers are consistent: an id names one adapter everywhere, defaults lie in their ranges", spec: "§6.3",
                        applies: offersAdapters) { p in
            var seen: [String: AdapterOffer] = [:]
            for d in p.operations {
                for m in d.models {
                    let adapters = m.adapters ?? []
                    try check(Set(adapters.map(\.id)).count == adapters.count, "\(d.operation) / \(m.id) lists an adapter twice")
                    try check((m.maxAdapters ?? 1) >= 1, "\(d.operation) / \(m.id): max_adapters below 1")
                    for a in adapters {
                        let range = a.strength
                        try check(range.min <= range.defaultValue && range.defaultValue <= range.max,
                                  "\(a.id): default strength \(range.defaultValue) is outside \(range.min)–\(range.max)")
                        try check(a.kind != .ic || !(a.slots ?? []).isEmpty, "\(a.id) is ic but has no slots")
                        if let first = seen[a.id] {
                            try check(first.license == a.license && first.kind == a.kind && first.slots == a.slots,
                                      "adapter \(a.id) is described differently in two offers")
                        }
                        seen[a.id] = a
                    }
                }
            }
            return nil
        },
        ConformanceTest("BASE-011", "The operations list has an ETag, and If-None-Match answers 304", spec: "§6") { p in
            let first = try await p.wire.send("GET", "operations")
            guard let etag = first.header("ETag") else { throw Failure("GET operations has no ETag") }
            try expect(try await p.wire.send("GET", "operations", headers: ["If-None-Match": etag]), 304, "If-None-Match: \(etag)", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-012", "One descriptor by name matches the list; an unknown one is 404 unknown_operation", spec: "§6") { p in
            let d = p.operations[0]
            let reply = try await p.wire.send("GET", "operations/\(d.operation)")
            try expect(reply, 200, "GET operations/\(d.operation)", schemas: p.schemas)
            try check(try reply.decode(Descriptor.self) == d, "operations/\(d.operation) differs from the list's entry")
            try expect(try await p.wire.send("GET", "operations/x.conformance-missing"), 404, code: "unknown_operation",
                       "GET operations/x.conformance-missing", schemas: p.schemas)
            return nil
        },

        // MARK: Jobs (§7)
        ConformanceTest("BASE-020", "A job: 201 with Location, then held with a valid result, plan and provenance", spec: "§7, §10",
                        applies: needsOperation) { p in
            let (d, request) = p.baseOperation!
            let reply = try await p.wire.json("POST", "jobs", request)
            try expect(reply, 201, "POST jobs (\(d.operation))", schemas: p.schemas)
            try p.schemas.require(reply.body, "base/job.schema.json", "the submitted job")
            let submitted = try reply.decode(Job.self)
            try check(reply.header("Location")?.hasSuffix("/jobs/\(submitted.id)") == true,
                      "Location is \(reply.header("Location") ?? "missing"), not …/jobs/\(submitted.id)")
            let job = try await p.settle(submitted)
            try p.schemas.require(try JSONValue(encoding: job), "base/job.schema.json", "the held job")
            try check(job.state == .holding && job.outcome == .succeeded, "ended \(job.state.rawValue) \(job.outcome?.rawValue ?? "")")
            guard let result = job.result else { throw Failure("a held job has no result") }
            try check(!result.outputs.isEmpty, "no outputs")
            try check(result.provenance.engine.id == p.info.id, "provenance names engine \(result.provenance.engine.id), not \(p.info.id)")
            try check(d.models.contains { $0.id == result.provenance.model.id }, "provenance names model \(result.provenance.model.id), which \(d.operation) doesn't offer")
            try check(job.plan?.model.id == result.provenance.model.id, "plan and provenance name different models")
            try check(job.retention.outputsExpireAt != nil, "a held job has no outputs_expire_at")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-021", "Request errors: 400 invalid_request, 404 unknown_operation, 422 unsupported_parameter, with valid error bodies",
                        spec: "§7.1, §12", applies: needsOperation) { p in
            let (d, request) = p.baseOperation!
            let malformed = try await p.wire.send("POST", "jobs", headers: ["Content-Type": "application/json"], body: Data("{\"operation\":".utf8))
            try expect(malformed, 400, code: "invalid_request", "a malformed body", schemas: p.schemas)
            try expect(try await p.wire.json("POST", "jobs", JobRequest(operation: "x.conformance-missing")), 404,
                       code: "unknown_operation", "an unknown operation", schemas: p.schemas)
            var unknown = request
            unknown.params = ["conformance_unknown_param": 1]
            try expect(try await p.wire.json("POST", "jobs", unknown), 422, code: "unsupported_parameter", "an undeclared parameter",
                       schemas: p.schemas)
            if let required = d.inputs.first(where: \.required) {
                var missing = request
                missing.inputs?[required.name] = nil
                try expect(try await p.wire.json("POST", "jobs", missing), 400, code: "invalid_request",
                           "a missing required input (\(required.name))", schemas: p.schemas)
            }
            return nil
        },
        ConformanceTest("BASE-022", "An Idempotency-Key repeated returns the original job", spec: "§7.1", applies: needsOperation) { p in
            let (_, request) = p.baseOperation!
            let key = "conformance-\(UUID().uuidString)"
            let first = try await p.wire.json("POST", "jobs", request, headers: ["Idempotency-Key": key])
            let second = try await p.wire.json("POST", "jobs", request, headers: ["Idempotency-Key": key])
            try check([200, 201].contains(second.status), "the repeat answered \(second.status)")
            let a = try first.decode(Job.self), b = try second.decode(Job.self)
            try check(a.id == b.id, "the repeat made a new job (\(b.id), not \(a.id))")
            await p.confirm(try await p.settle(a))
            return nil
        },
        ConformanceTest("BASE-023", "A long poll on a held job answers at once with a valid snapshot", spec: "§7.3",
                        applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let t0 = Date()
            let reply = try await p.wire.send("GET", "jobs/\(job.id)?wait=20", timeout: 40)
            try expect(reply, 200, "GET jobs/{id}?wait=20", schemas: p.schemas)
            try p.schemas.require(reply.body, "base/job.schema.json", "the snapshot")
            let elapsed = Date().timeIntervalSince(t0)
            try check(elapsed < 3, "?wait=20 on a held job took \(Int(elapsed)) s; it should answer at once")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-024", "GET jobs lists the caller's jobs and filters by state", spec: "§7.3", applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            struct List: Decodable { var jobs: [Job] }
            let all = try (try await p.wire.send("GET", "jobs")).decode(List.self).jobs
            let held = try (try await p.wire.send("GET", "jobs?state=holding")).decode(List.self).jobs
            try check(all.contains { $0.id == job.id }, "GET jobs doesn't list \(job.id)")
            try check(held.contains { $0.id == job.id } && held.allSatisfy { $0.state == .holding }, "?state=holding filters wrongly")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-025", "An output: its media type, its bytes and an ETag of its SHA-256", spec: "§7.3", applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let reply = try await p.wire.send("GET", "jobs/\(job.id)/outputs/0")
            try expect(reply, 200, "GET outputs/0", schemas: p.schemas)
            let output = job.result!.outputs[0]
            try check(reply.header("Content-Type")?.hasPrefix(output.mediaType) == true,
                      "Content-Type \(reply.header("Content-Type") ?? "missing"), output says \(output.mediaType)")
            try check(reply.body.count == output.bytes, "\(reply.body.count) bytes, output says \(output.bytes)")
            try check(Hex.sha256(reply.body) == output.sha256, "the bytes don't hash to the output's sha256")
            try check(reply.header("ETag") == "\"sha256:\(output.sha256)\"", "ETag \(reply.header("ETag") ?? "missing")")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-026", "Outputs serve byte ranges: 206 with Content-Range, suffixes, and 416 beyond the end", spec: "§7.3",
                        applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let (output, full) = try await p.output(job)
            let total = output.bytes
            let head = try await p.wire.send("GET", "jobs/\(job.id)/outputs/0", headers: ["Range": "bytes=0-9"])
            try expect(head, 206, "Range: bytes=0-9", schemas: p.schemas)
            try check(head.body == full.prefix(10), "bytes 0–9 differ from the full body's")
            try check(head.header("Content-Range") == "bytes 0-9/\(total)", "Content-Range \(head.header("Content-Range") ?? "missing")")
            let tail = try await p.wire.send("GET", "jobs/\(job.id)/outputs/0", headers: ["Range": "bytes=-5"])
            try expect(tail, 206, "Range: bytes=-5", schemas: p.schemas)
            try check(tail.body == full.suffix(5), "the last 5 bytes differ")
            try expect(try await p.wire.send("GET", "jobs/\(job.id)/outputs/0", headers: ["Range": "bytes=\(total)-"]), 416,
                       "Range: bytes=\(total)-", schemas: p.schemas)
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-027", "Confirm purges: the job is purged and succeeded, its outputs answer 410 gone", spec: "§7.3, §13",
                        applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let reply = try await p.wire.send("POST", "jobs/\(job.id)/confirm")
            try expect(reply, 200, "POST confirm", schemas: p.schemas)
            let confirmed = try reply.decode(Job.self)
            try check(confirmed.state == .purged && confirmed.outcome == .succeeded, "after confirm: \(confirmed.state.rawValue) \(confirmed.outcome?.rawValue ?? "")")
            try expect(try await p.wire.send("GET", "jobs/\(job.id)/outputs/0"), 410, code: "gone", "the output after confirm", schemas: p.schemas)
            return nil
        },
        ConformanceTest("BASE-028", "Release is idempotent; a released job's outputs answer 410", spec: "§7.3, §13", applies: needsOperation) { p in
            let reply = try await p.wire.json("POST", "jobs", p.baseOperation!.1)
            let job = try reply.decode(Job.self)
            let released = try (try await p.wire.send("DELETE", "jobs/\(job.id)")).decode(Job.self)
            try check(released.state == .purged || released.state == .holding, "after release: \(released.state.rawValue)")
            let settled = try await p.settle(released)
            try check(settled.state == .purged, "a released job ended \(settled.state.rawValue)")
            try check([.cancelled, .succeeded].contains(settled.outcome), "outcome \(settled.outcome?.rawValue ?? "none")")
            try expect(try await p.wire.send("DELETE", "jobs/\(job.id)"), 200, "a second release", schemas: p.schemas)
            if settled.outcome == .succeeded {
                try expect(try await p.wire.send("GET", "jobs/\(job.id)/outputs/0"), 410, code: "gone", "a released output", schemas: p.schemas)
            }
            return settled.outcome == .succeeded ? Note("The job finished before the release reached it; its outputs were discarded.") : nil
        },

        // MARK: Uploads and inputs (§8)
        ConformanceTest("BASE-029", "Adapters: a run lists them in provenance with licence and strength; unknown, out-of-range and policy-failing ones are refused",
                        spec: "§6.3, §10", applies: { p in
                            if let reason = offersAdapters(p) { return reason }
                            return plainAdapter(p) == nil ? "no operation the suite can drive offers a plain adapter" : nil
                        }) { p in
            let (d, base, model, adapter) = plainAdapter(p)!
            var request = base
            request.model = model.id
            request.adapters = [AdapterRequest(id: adapter.id)]
            let job = try await p.succeed(request)
            guard let applied = job.result?.provenance.adapters else { throw Failure("\(d.operation) with \(adapter.id): provenance lists no adapters") }
            try check(applied.map(\.id) == [adapter.id], "provenance.adapters is \(applied.map(\.id)), not [\(adapter.id)]")
            try check(applied[0].license == adapter.license, "provenance gives \(adapter.id) another licence than its offer")
            try check(applied[0].strength == adapter.strength.defaultValue,
                      "\(adapter.id) ran at \(applied[0].strength); without a strength it runs at its default, \(adapter.strength.defaultValue)")
            await p.confirm(job)

            var unknown = request
            unknown.adapters = [AdapterRequest(id: "conformance-missing-adapter")]
            try expect(try await p.wire.json("POST", "jobs", unknown), 422, code: "unsupported_parameter", "an adapter no offer lists",
                       schemas: p.schemas)
            var strong = request
            strong.adapters = [AdapterRequest(id: adapter.id, strength: adapter.strength.max + 1)]
            try expect(try await p.wire.json("POST", "jobs", strong), 422, code: "out_of_limits", "a strength above \(adapter.id)'s range",
                       schemas: p.schemas)
            let plain = (model.adapters ?? []).filter { $0.kind == .plain }
            if plain.count > model.adapterLimit {
                var many = request
                many.adapters = plain.prefix(model.adapterLimit + 1).map { AdapterRequest(id: $0.id) }
                try expect(try await p.wire.json("POST", "jobs", many), 422, code: "out_of_limits",
                           "more adapters than \(model.id)'s max_adapters", schemas: p.schemas)
            }
            if let restricted = plain.first(where: { $0.license.commercialUse != .yes }) {
                var policy = request
                policy.adapters = [AdapterRequest(id: restricted.id)]
                policy.policy = Policy(license: .commercialUse)
                try expect(try await p.wire.json("POST", "jobs", policy), 422, code: "policy_unmet",
                           "\(restricted.id) (\(restricted.license.spdx)) under policy commercial-use", schemas: p.schemas)
            }
            return nil
        },
        ConformanceTest("BASE-030", "Uploads: 201 with the right size and SHA-256, at most an hour's expiry, and single use", spec: "§8",
                        applies: { p in
                            p.operations.contains { d in d.inputs.contains { $0.kind == .image && $0.required } && p.minimalRequest(d) != nil }
                                ? nil : "no operation takes an image input the suite can supply"
                        }) { p in
            let image = Fixtures.png()
            let digest = Data(Hex.data(Hex.sha256(image))!).base64EncodedString()
            let reply = try await p.wire.send("POST", "uploads", headers: ["Content-Type": "image/png", "Content-Digest": "sha-256=:\(digest):"],
                                              body: image)
            try expect(reply, 201, "POST uploads", schemas: p.schemas)
            try p.schemas.require(reply.body, "base/upload.schema.json", "the upload")
            let upload = try reply.decode(Upload.self)
            try check(upload.bytes == image.count && upload.sha256 == Hex.sha256(image), "size or sha256 differ from what was sent")
            try check(upload.expiresAt <= Date().addingTimeInterval(3_600 + 60), "expires_at is more than an hour away (§8)")
            let d = p.operations.first { d in d.inputs.contains { $0.kind == .image && $0.required } && p.minimalRequest(d) != nil }!
            let name = d.inputs.first { $0.kind == .image && $0.required }!.name
            var request = p.minimalRequest(d)!
            request.inputs?[name] = .one(.upload(upload.uploadID))
            let job = try await p.succeed(request)
            await p.confirm(job)
            let reuse = try await p.wire.json("POST", "jobs", request)
            try check(reuse.status == 422 || reuse.status == 404, "a used upload was accepted again (\(reuse.status))")
            return nil
        },
        ConformanceTest("BASE-031", "An upload whose Content-Digest doesn't match is refused", spec: "§8") { p in
            let reply = try await p.wire.send("POST", "uploads", headers: [
                "Content-Type": "image/png", "Content-Digest": "sha-256=:\(Data(repeating: 0, count: 32).base64EncodedString()):",
            ], body: Fixtures.png())
            try check((400..<500).contains(reply.status) && reply.errorCode != nil, "a wrong Content-Digest answered \(reply.status)")
            try p.schemas.require(reply.body, "base/error.schema.json", "the refusal")
            return nil
        },

        // MARK: Grants (§9)
        ConformanceTest("BASE-040", "Grants: the engine pulls with the bearer token, and fails the job on a wrong SHA-256", spec: "§9",
                        applies: { p in
                            if let reason = feature(.grants)(p) { return reason }
                            if !p.isLoopback && p.options.grantHost == nil { return "a LAN engine needs --grant-host (this machine's address as the engine sees it)" }
                            return p.operations.contains { d in d.inputs.contains { $0.kind == .image && $0.required } && p.minimalRequest(d) != nil }
                                ? nil : "no operation takes an image input the suite can supply"
                        }) { p in
            let server = GrantServer(loopbackOnly: p.isLoopback)
            _ = try await server.start()
            defer { server.stop() }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("mes-conformance-\(UUID().uuidString).png")
            try Fixtures.png().write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let host = p.options.grantHost ?? "127.0.0.1"
            let d = p.operations.first { d in d.inputs.contains { $0.kind == .image && $0.required } && p.minimalRequest(d) != nil }!
            let name = d.inputs.first { $0.kind == .image && $0.required }!.name
            var request = p.minimalRequest(d)!
            request.inputs?[name] = .one(.grant(try server.grant(file, mediaType: "image/png", host: host)))
            await p.confirm(try await p.succeed(request))
            var tampered = try server.grant(file, mediaType: "image/png", host: host)
            tampered.sha256 = String(repeating: "0", count: 64)
            request.inputs?[name] = .one(.grant(tampered))
            let failed = try await p.run(request)
            try check(failed.outcome == .failed, "a grant with the wrong sha256 ended \(failed.outcome?.rawValue ?? "none")")
            try check(failed.error?.code == "input_fetch_failed", "error \(failed.error?.code ?? "none"), not input_fetch_failed")
            return nil
        },

        // MARK: Events (§11)
        ConformanceTest("BASE-050", "SSE: framed events that validate, rising seq, output_ready, then job.ended after confirm", spec: "§11",
                        applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            async let stream = p.wire.frames("jobs/\(job.id)/events", timeout: 30) { $0.event == "job.ended" }
            try await Task.sleep(for: .milliseconds(300))
            await p.confirm(job)
            let (contentType, frames, _) = try await stream
            try check(contentType?.hasPrefix("text/event-stream") == true, "Content-Type \(contentType ?? "missing")")
            var last = 0
            var types: [String] = []
            for frame in frames {
                let value = try MESJSON.decoder.decode(JSONValue.self, from: Data(frame.data.utf8))
                try p.schemas.require(value, "base/event.schema.json", "event \(frame.id ?? "?")")
                let seq = value["seq"]?.intValue ?? 0
                try check(seq > last, "seq \(seq) after \(last)")
                try check(frame.id == String(seq), "id: \(frame.id ?? "missing") for seq \(seq)")
                try check(frame.event == value["type"]?.stringValue, "event: \(frame.event ?? "missing") for type \(value["type"]?.stringValue ?? "")")
                last = seq
                types.append(frame.event ?? "")
            }
            try check(types.contains("job.state") && types.contains("job.output_ready"), "events seen: \(types)")
            try check(types.last == "job.ended", "the stream didn't deliver job.ended after confirm (saw \(types.suffix(3)))")
            return nil
        },
        ConformanceTest("BASE-051", "SSE resumes after Last-Event-ID", spec: "§11", applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let (_, frames, _) = try await p.wire.frames("jobs/\(job.id)/events", lastEventID: 2, timeout: 15) { $0.event == "job.output_ready" }
            try check(frames.first?.id == "3", "after Last-Event-ID: 2 the first id was \(frames.first?.id ?? "none")")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-052", "WebSocket: pong, engine.health on \"*\", the client's job events, error messages", spec: "§11",
                        applies: { p in feature(.websocket)(p) ?? needsOperation(p) }) { p in
            let socket = p.wire.webSocket("ws")
            defer { socket.cancel(with: .normalClosure, reason: nil) }
            func next() async throws -> JSONValue {
                guard case .string(let text) = try await socket.receive() else { throw Failure("a non-text WebSocket message") }
                return try MESJSON.decoder.decode(JSONValue.self, from: Data(text.utf8))
            }
            try await socket.send(.string(#"{"type":"ping"}"#))
            try check(try await next()["type"] == "pong", "no pong")
            try await socket.send(.string(#"{"type":"subscribe","jobs":"*"}"#))
            let health = try await next()
            try check(health["type"] == "engine.health", "the first message after subscribing to \"*\" was \(health["type"]?.stringValue ?? "?")")
            let job = try (try await p.wire.json("POST", "jobs", p.baseOperation!.1)).decode(Job.self)
            var sawReady = false
            for _ in 0..<200 where !sawReady {
                let m = try await next()
                if m["job"]?.stringValue == job.id {
                    try p.schemas.require(m, "base/event.schema.json", "a WebSocket event")
                    sawReady = m["type"] == "job.output_ready"
                }
            }
            try check(sawReady, "no job.output_ready for \(job.id)")
            try await socket.send(.string(#"{"type":"cancel","job":"job_conformance_missing"}"#))
            var sawError = false
            for _ in 0..<50 where !sawError { sawError = try await next()["type"] == "error" }
            try check(sawError, "no error message for an unknown job")
            await p.confirm(job)
            return nil
        },

        // MARK: Health, retention (§13, §14)
        ConformanceTest("BASE-060", "Health validates", spec: "§14") { p in
            let reply = try await p.wire.send("GET", "health")
            try expect(reply, 200, "GET health", schemas: p.schemas)
            try p.schemas.require(reply.body, "base/health.schema.json", "GET health")
            return nil
        },
        ConformanceTest("BASE-070", "Retention deadlines respect the engine's TTLs", spec: "§13", applies: needsOperation) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let now = Date()
            if let expires = job.retention.outputsExpireAt {
                try check(expires <= now.addingTimeInterval(TimeInterval(p.info.retention.outputsTTLSeconds) + 60),
                          "outputs_expire_at is beyond outputs_ttl_s")
            }
            try check(job.retention.recordExpiresAt <= job.createdAt.addingTimeInterval(TimeInterval(p.info.retention.jobRecordTTLSeconds) + 60),
                      "record_expires_at is beyond job_record_ttl_s")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("BASE-071", "Outputs expire: after outputs_ttl_s the job is expired and its outputs answer 410", spec: "§13 rule 2",
                        applies: { p in
                            if let reason = needsOperation(p) { return reason }
                            return p.info.retention.outputsTTLSeconds <= p.options.maxTTLWait ? nil
                                : "outputs_ttl_s is \(p.info.retention.outputsTTLSeconds) s (observed only up to \(p.options.maxTTLWait) s)"
                        }) { p in
            let job = try await p.succeed(p.baseOperation!.1)
            let wait = (job.retention.outputsExpireAt ?? Date()).timeIntervalSinceNow + 3
            try await Task.sleep(for: .seconds(max(0, wait)))
            try expect(try await p.wire.send("GET", "jobs/\(job.id)/outputs/0"), 410, code: "gone", "an output after its TTL", schemas: p.schemas)
            let expired = try (try await p.wire.send("GET", "jobs/\(job.id)")).decode(Job.self)
            try check(expired.state == .purged && expired.outcome == .expired, "after the TTL: \(expired.state.rawValue) \(expired.outcome?.rawValue ?? "")")
            return nil
        },

        // MARK: MCP (§15)
        ConformanceTest("BASE-080", "MCP: a session lists one tool per operation (dots → underscores) and the four helpers", spec: "§15",
                        applies: feature(.mcp)) { p in
            let headers = ["Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                           "MCP-Protocol-Version": "2025-06-18"]
            let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mes-conformance","version":"0.1"}}}"#
            let first = try await p.wire.send("POST", "mcp", headers: headers, body: Data(initialize.utf8))
            try check(first.status == 200, "initialize answered \(first.status)")
            guard let session = first.header("Mcp-Session-Id") else { throw Failure("no Mcp-Session-Id") }
            var h = headers
            h["Mcp-Session-Id"] = session
            _ = try await p.wire.send("POST", "mcp", headers: h, body: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            let list = try await p.wire.send("POST", "mcp", headers: h, body: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
            let message = String(decoding: list.body, as: UTF8.self).split(separator: "\n")
                .compactMap { $0.hasPrefix("data:") ? String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) : nil }
                .last { !$0.isEmpty } ?? String(decoding: list.body, as: UTF8.self)
            let value = try MESJSON.decoder.decode(JSONValue.self, from: Data(message.utf8))
            let names = Set(value["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? [])
            let expected = Set(p.operations.map { $0.operation.replacingOccurrences(of: ".", with: "_") })
                .union(["mes_list_operations", "mes_get_job", "mes_cancel_job", "mes_confirm_job"])
            try check(expected.isSubset(of: names), "missing tools: \(expected.subtracting(names).sorted())")
            _ = try? await p.wire.send("DELETE", "mcp", headers: h)
            return nil
        },

        // MARK: Pairing (§5)
        ConformanceTest("BASE-090", "Pairing: the token is handed out once, and unpairing revokes it", spec: "§5",
                        applies: { p in
                            if let reason = paired(p) { return reason }
                            return p.options.pairing == nil ? "run with --pair to test pairing (the engine's operator approves)" : nil
                        }) { p in
            let run = p.options.pairing!
            let again = try await p.wire.send("POST", "pairings/\(run.pairingID)/confirm", headers: ["Content-Type": "application/json"],
                                              body: Data("{}".utf8))
            try check(again.status == 404 || again.status == 410, "a second confirm answered \(again.status), not 404")
            try expect(try await p.wire.send("DELETE", "pairings/self"), 204, "DELETE pairings/self", schemas: p.schemas)
            try expect(try await p.wire.send("GET", "operations"), 401, code: "unauthorized", "the token after unpairing", schemas: p.schemas)
            return nil
        },
    ]
}
