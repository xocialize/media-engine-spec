import CoreGraphics
import Foundation
import ImageIO
import MESCore

/// The Mesh profile 0.1 tests (MESH-nnn, spec/profiles/mesh.md §6), for the operations the engine offers. Each asks for an
/// offer's cheapest tier and its fewest faces, so the slowest models fit `--job-timeout`.
enum MeshTests {
    typealias P = MeshProfile.Param
    typealias K = MeshProfile.SupportsKey
    typealias L = MeshProfile.LimitField

    static var meshOps: [String] { MeshProfile.operations.operations.keys.sorted() }

    static func offers(_ ops: String...) -> @Sendable (Probe) -> String? { offers(contentsOf: ops) }

    static func offers(contentsOf ops: [String]) -> @Sendable (Probe) -> String? {
        { p in
            guard p.info.profiles.contains(where: { $0.id == MeshProfile.id }) else { return "the engine doesn't offer the Mesh profile" }
            return ops.contains { p.descriptor($0) != nil } ? nil : "the engine offers none of \(ops.joined(separator: ", "))"
        }
    }

    static func defaultOffer(_ d: Descriptor) -> ModelOffer? {
        d.models.first { $0.isDefault == true } ?? d.models.first { $0.namedOnly != true }
    }
    static func list(_ m: ModelOffer, _ key: String) -> [JSONValue] { m.supports(key)?.arrayValue ?? [] }
    static func tier(_ m: ModelOffer) -> QualityTier { m.qualityTiers.contains(.draft) ? .draft : (m.qualityTiers.first ?? .standard) }
    static func has(_ d: Descriptor, _ param: String) -> Bool { d.params["properties"]?[param] != nil }

    /// The fewest faces a request to `m` may ask for: its `min_faces`, else the descriptor's, else the parameter's minimum.
    static func fewestFaces(_ d: Descriptor, _ m: ModelOffer) -> Int {
        let schemaMin = d.params["properties"]?[P.maxFaces]?["minimum"]?.intValue ?? 100
        return max(schemaMin, Int(m.limits?.value(L.minFaces) ?? d.limits?.value(L.minFaces) ?? 0))
    }

    static func imageInput(_ data: Data = Fixtures.ball()) -> RequestInput { .one(.inline(mediaType: "image/png", data: data)) }
    static func meshInput(_ data: Data) -> RequestInput { .one(.inline(mediaType: MeshProfile.mediaType, data: data)) }

    /// A request offer `m` of `d` can serve, at its cheapest tier and fewest faces. Names the model when `named`.
    static func request(_ p: Probe, _ d: Descriptor, _ m: ModelOffer, named: Bool = true) -> JobRequest {
        var inputs: [String: RequestInput] = [:], params: [String: JSONValue] = [:]
        switch d.operation {
        case "mesh.generate":
            inputs[MeshProfile.Input.image] = imageInput()
            if has(d, P.maxFaces) { params[P.maxFaces] = .number(Double(fewestFaces(d, m))) }
        case "mesh.rig":
            inputs[MeshProfile.Input.mesh] = meshInput(p.meshFixture ?? Data())
            if m.supports(K.autoSkeleton)?.boolValue == false, let template = list(m, K.skeletons).first {
                params[P.skeleton] = template
            }
        default: break
        }
        if has(d, P.quality) { params[P.quality] = .string(tier(m).rawValue) }
        return JobRequest(operation: d.operation, inputs: inputs, params: params, model: named ? m.id : nil, policy: Probe.acceptance(d))
    }

    static func output(_ job: Job, _ name: String) throws -> Output {
        guard let o = job.result?.outputs.first(where: { $0.name == name }) else { throw Failure("\(job.operation) returned no '\(name)' output") }
        return o
    }

    /// A mesh output, checked against its file (Mesh §1.1, §1.2, §1.6): a GLB by the conventions, its facts reported and
    /// agreeing, a flat `generate` result warned (§1.8). Returns the parsed file.
    static func mesh(_ p: Probe, _ job: Job) async throws -> (GLB, Output) {
        let o = try output(job, MeshProfile.Output.mesh)
        let what = "\(job.operation) output \(o.name)"
        try check(o.kind == .mesh, "\(what) is \(o.kind.rawValue), not mesh")
        try check(o.mediaType == MeshProfile.mediaType, "\(what) is \(o.mediaType), not \(MeshProfile.mediaType)")
        guard let vertices = o.vertices, let faces = o.faces, let bounds = o.bounds else {
            throw Failure("\(what) doesn't report vertices, faces and bounds (Base §10.1, Mesh §1.6)")
        }
        let (_, data) = try await p.output(job, o.index)
        let glb: GLB
        do { glb = try GLB(data: data) } catch { throw Failure("\(what) isn't a GLB: \(error)") }
        let problems = glb.problems()
        try check(problems.isEmpty, "\(what) breaks Mesh §1.1/§1.2: \(problems.prefix(3).joined(separator: "; "))")
        let facts = try glb.facts()
        try check(facts.vertices == vertices, "\(what): the file has \(facts.vertices) vertices, the output says \(vertices)")
        try check(facts.faces == faces, "\(what): the file has \(facts.faces) faces, the output says \(faces)")
        let tolerance = 1e-3 * max(facts.bounds.extents.max() ?? 1, 1e-3)
        try check(zip(facts.bounds.min + facts.bounds.max, bounds.min + bounds.max).allSatisfy { abs($0 - $1) <= tolerance },
                  "\(what): the file's bounds are \(facts.bounds.min)…\(facts.bounds.max), the output says \(bounds.min)…\(bounds.max)")
        try check(facts.textureSize == o.textureSize,
                  "\(what): texture_size is \(o.textureSize.map(String.init) ?? "absent"), the file's largest texture is \(facts.textureSize.map(String.init) ?? "none")")
        try check(facts.joints == o.joints, "\(what): joints is \(o.joints.map(String.init) ?? "absent"), the file's skin has \(facts.joints.map(String.init) ?? "none")")
        if job.operation == "mesh.generate", bounds.thinness < MeshProfile.flatRatio {
            try check(job.warnings.contains { $0.code == MeshProfile.WarningCode.flatResult },
                      "\(what) is flat (\(bounds.thinness)) without a flat_result warning (Mesh §1.8)")
        }
        return (glb, o)
    }

    /// The preview (Mesh §1.7): a square PNG of at least 512 px with transparent pixels. Returns its text: the PNG
    /// `Comment` and `Description`, and the EXIF `UserComment` (where ImageIO writes a PNG comment).
    static func preview(_ p: Probe, _ job: Job) async throws -> [String] {
        let o = try output(job, MeshProfile.Output.preview)
        try check(o.kind == .image && o.mediaType == "image/png", "\(job.operation)'s preview is \(o.kind.rawValue) \(o.mediaType), not a PNG image")
        let (_, data) = try await p.output(job, o.index)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("\(job.operation)'s preview doesn't decode")
        }
        try check(image.width == image.height && image.width >= MeshProfile.minPreviewSize,
                  "\(job.operation)'s preview is \(image.width)×\(image.height); Mesh §1.7 asks for a square of at least 512")
        try check(o.width == image.width && o.height == image.height, "\(job.operation)'s preview reports \(o.width ?? 0)×\(o.height ?? 0), the file is \(image.width)×\(image.height)")
        try check(hasTransparency(image), "\(job.operation)'s preview has no transparent pixels (Mesh §1.7: a transparent background)")
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:], exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        return [png[kCGImagePropertyPNGComment], png[kCGImagePropertyPNGDescription], exif[kCGImagePropertyExifUserComment]].compactMap { $0 as? String }
    }

    static func hasTransparency(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn && stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }

    static func refuse(_ p: Probe, _ request: JobRequest, _ status: Int, _ code: String, _ what: String) async throws {
        let reply = try await p.wire.json("POST", "jobs", request)
        if reply.status == 201, let job = try? reply.decode(Job.self) { _ = try? await p.wire.send("DELETE", "jobs/\(job.id)") }
        try expect(reply, status, code: code, what, schemas: p.schemas)
    }

    static func find(_ p: Probe, _ op: String, _ test: (ModelOffer) -> Bool) -> (Descriptor, ModelOffer)? {
        guard let d = p.descriptor(op), let m = d.models.first(where: test) else { return nil }
        return (d, m)
    }

    static let all: [ConformanceTest] = [
        ConformanceTest("MESH-001", "Descriptors match the profile table: required inputs and outputs of the right kinds, only vocabulary parameters",
                        spec: "Mesh §3, §6", applies: { p in offers(contentsOf: meshOps)(p) }) { p in
            for d in p.operations where d.profile == MeshProfile.id {
                guard let spec = MeshProfile.operations.operations[d.operation] else {
                    throw Failure("\(d.operation) isn't a Mesh 0.1 operation (Base §6 rule 6)")
                }
                let inputs = Dictionary(d.inputs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                for (name, io) in spec.inputs {
                    if io.required == true { try check(inputs[name]?.required == true, "\(d.operation) doesn't require input '\(name)'") }
                    if let input = inputs[name] { try check(input.kind == io.kind, "\(d.operation) input '\(name)' is \(input.kind.rawValue), not \(io.kind.rawValue)") }
                }
                for name in inputs.keys { try check(spec.inputs[name] != nil, "\(d.operation) has input '\(name)', which the profile doesn't define") }
                let outputs = Dictionary(d.outputs.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
                for (name, io) in spec.outputs {
                    guard let out = outputs[name] else { throw Failure("\(d.operation) lacks output '\(name)'") }
                    try check(out.kind == io.kind, "\(d.operation) output '\(name)' is \(out.kind.rawValue), not \(io.kind.rawValue)")
                    try check((out.min ?? 1) >= 1, "\(d.operation) output '\(name)' may be absent; Mesh §1.7 makes it always present")
                }
                for name in (d.params["properties"]?.objectValue ?? [:]).keys where !name.hasPrefix("x-") {
                    try check(spec.vocabulary.contains(name), "\(d.operation) param '\(name)' isn't Mesh vocabulary (Base §6 rule 1)")
                }
                for name in d.params["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                    try check(spec.vocabulary.contains(name), "\(d.operation) requires '\(name)', which isn't vocabulary")
                }
            }
            return nil
        },
        ConformanceTest("MESH-002", "Offers' supports keys have the profile's types and their limits are the profile's fields",
                        spec: "Mesh §4", applies: { p in offers(contentsOf: meshOps)(p) }) { p in
            for d in p.operations where d.profile == MeshProfile.id {
                let name = d.operation.split(separator: ".")[1]
                if let limits = d.limits {
                    try p.schemas.require(try JSONValue(encoding: limits), "profiles/mesh/supports.schema.json#/$defs/\(name)_limits", "\(d.operation) limits")
                }
                for m in d.models {
                    try p.schemas.require(.object(m.supports ?? [:]), "profiles/mesh/supports.schema.json#/$defs/\(name)_supports", "\(d.operation) / \(m.id) supports")
                    if let limits = m.limits {
                        try p.schemas.require(try JSONValue(encoding: limits), "profiles/mesh/supports.schema.json#/$defs/\(name)_limits", "\(d.operation) / \(m.id) limits")
                    }
                }
            }
            return nil
        },
        ConformanceTest("MESH-003", "Mesh outputs are GLB by the conventions, report vertices, faces and bounds, the file agrees, and flat results are warned",
                        spec: "Mesh §1.1, §1.2, §1.6, §1.8, Base §10.1", applies: { p in offers(contentsOf: meshOps)(p) }) { p in
            var notes: [String] = []
            for d in p.operations where d.profile == MeshProfile.id {
                for m in d.models where m.namedOnly != true {
                    let job = try await p.succeed(request(p, d, m))
                    let (_, o) = try await mesh(p, job)
                    notes.append("\(m.id): \(o.vertices!) vertices, \(o.faces!) faces\(o.textureSize.map { ", \($0) px texture" } ?? "")\(o.joints.map { ", \($0) joints" } ?? "")")
                    await p.confirm(job)
                }
            }
            return Note(notes.joined(separator: "; "))
        },
        ConformanceTest("MESH-004", "Placement: centered at the origin, grounded at Y = 0, the longest extent size_m",
                        spec: "Mesh §1.4", applies: { p in offers("mesh.generate")(p) }) { p in
            let d = p.descriptor("mesh.generate")!
            guard let m = defaultOffer(d) else { throw Failure("mesh.generate has no default offer") }
            let a = try await p.succeed(request(p, d, m))
            let (_, ao) = try await mesh(p, a)
            let ab = ao.bounds!
            try check(abs((ab.extents.max() ?? 0) - 1) <= 0.01, "the default size_m is 1, but the longest extent is \(ab.extents.max() ?? 0)")
            try check(ab.center.allSatisfy { abs($0) <= 0.01 }, "centered (the default), but the box's centre is \(ab.center)")
            await p.confirm(a)
            guard has(d, P.placement), has(d, P.size) else { return Note("the descriptor takes no placement or size_m: the defaults checked") }
            var r = request(p, d, m)
            r.params?[P.placement] = "grounded"
            r.params?[P.size] = 2
            let b = try await p.succeed(r)
            let (_, bo) = try await mesh(p, b)
            let bb = bo.bounds!
            try check(abs((bb.extents.max() ?? 0) - 2) <= 0.02, "size_m 2, but the longest extent is \(bb.extents.max() ?? 0)")
            try check(abs(bb.min[1]) <= 0.02, "grounded, but the lowest point is at y = \(bb.min[1])")
            try check(abs(bb.center[0]) <= 0.02 && abs(bb.center[2]) <= 0.02, "grounded, but not centred on X and Z: \(bb.center)")
            try check(b.result?.effective[P.placement]?.stringValue == "grounded" && b.result?.effective[P.size]?.numberValue == 2,
                      "effective doesn't report placement grounded and size_m 2")
            await p.confirm(b)
            return nil
        },
        ConformanceTest("MESH-005", "Every mesh output comes with a preview: a square PNG of at least 512 px with transparent pixels",
                        spec: "Mesh §1.7", applies: { p in offers(contentsOf: meshOps)(p) }) { p in
            for d in p.operations where d.profile == MeshProfile.id {
                guard let m = defaultOffer(d) else { continue }
                let job = try await p.succeed(request(p, d, m, named: false))
                _ = try await preview(p, job)
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("MESH-006", "generate: faces within max_faces; the offer's gates and limits refuse; texture_size with vertex colours is 400; effective reports",
                        spec: "Mesh §2, §3.1, §4", applies: { p in offers("mesh.generate")(p) }) { p in
            let d = p.descriptor("mesh.generate")!
            guard let m = defaultOffer(d) else { throw Failure("mesh.generate has no default offer") }
            var r = request(p, d, m)
            r.params?[P.seed] = 11
            let job = try await p.succeed(r)
            let (_, o) = try await mesh(p, job)
            let asked = r.params?[P.maxFaces]?.intValue
            if let asked { try check(o.faces! <= asked, "\(o.faces!) faces, but max_faces was \(asked)") }
            let eff = job.result?.effective ?? [:]
            for name in [P.seed, P.maxFaces, P.texture, P.placement, P.size] {
                try check(eff[name] != nil, "effective doesn't report \(name) (Mesh §3.1)")
            }
            await p.confirm(job)
            var checked: [String] = []
            if has(d, P.texture), has(d, P.textureSize) {
                var bad = request(p, d, m)
                bad.params?[P.texture] = "vertex_colors"
                bad.params?[P.textureSize] = d.params["properties"]?[P.textureSize]?["enum"]?.arrayValue?.first ?? 1024
                try await refuse(p, bad, 400, "invalid_request", "texture_size with texture: vertex_colors")
                checked.append("texture_size with vertex_colors 400")
            }
            for x in d.models where x.namedOnly != true {
                if let floor = x.limits?.value(L.minFaces), let schemaMin = d.params["properties"]?[P.maxFaces]?["minimum"]?.numberValue,
                   floor > schemaMin, has(d, P.maxFaces) {
                    var bad = request(p, d, x)
                    bad.params?[P.maxFaces] = .number(max(schemaMin, floor - 1).rounded(.down))
                    try await refuse(p, bad, 422, "out_of_limits", "max_faces below \(x.id)'s min_faces")
                    checked.append("\(x.id) min_faces 422")
                }
                let gates: [(String, String, [JSONValue]?)] = [(P.resolution, K.resolutions, nil), (P.texture, K.textures, ["atlas"]),
                                                               (P.textureSize, K.textureSizes, nil)]
                for (param, key, absent) in gates where has(d, param) {
                    let listed = x.supports(key)?.arrayValue ?? absent ?? []
                    guard let value = d.params["properties"]?[param]?["enum"]?.arrayValue?.first(where: { !listed.contains($0) }) else { continue }
                    var bad = request(p, d, x)
                    bad.params?[param] = value
                    if param == P.textureSize { bad.params?[P.texture] = nil }
                    try await refuse(p, bad, 422, "unsupported_parameter", "\(param) \(value) to \(x.id), which doesn't list it")
                    checked.append("\(x.id) \(param) 422")
                }
            }
            return Note(checked.isEmpty ? "no refusals to check: every offer takes every value" : checked.joined(separator: ", "))
        },
        ConformanceTest("MESH-007", "generate: background removal is gated; a cut-out image is used as it is and reported as alpha",
                        spec: "Mesh §1.10, §3.1", applies: { p in offers("mesh.generate")(p) }) { p in
            let d = p.descriptor("mesh.generate")!
            guard let m = defaultOffer(d) else { throw Failure("mesh.generate has no default offer") }
            var r = request(p, d, m)
            r.inputs?[MeshProfile.Input.image] = imageInput(Fixtures.ball(transparent: true))
            let job = try await p.succeed(r)
            try check(job.result?.effective[P.background]?.stringValue == MeshProfile.alpha,
                      "a cut-out image reported background \(job.result?.effective[P.background]?.stringValue ?? "nothing"), not alpha")
            await p.confirm(job)
            if has(d, P.background), let (_, x) = find(p, "mesh.generate", { $0.supports(K.backgroundRemoval)?.boolValue != true && $0.namedOnly != true }) {
                var bad = request(p, d, x)
                bad.params?[P.background] = "remove"
                try await refuse(p, bad, 422, "unsupported_parameter", "background: remove to \(x.id), which can't")
                return Note("\(x.id) refused background removal")
            }
            return Note("every offer removes backgrounds")
        },
        ConformanceTest("MESH-008", "on_flat takes warn and fail; a result refused for flatness fails input_invalid with reason degenerate_result",
                        spec: "Mesh §1.8", applies: { p in offers("mesh.generate")(p) }) { p in
            let d = p.descriptor("mesh.generate")!
            guard has(d, P.onFlat) else { return Note("the descriptor doesn't take on_flat; flat results are always warned") }
            guard let m = defaultOffer(d) else { throw Failure("mesh.generate has no default offer") }
            for mode in MeshProfile.onFlatModes {
                var r = request(p, d, m)
                r.params?[P.onFlat] = .string(mode)
                let job = try await p.run(r)
                if job.outcome == .failed {
                    try check(mode == "fail" && job.error?.code == "input_invalid" && job.error?.reason == MeshProfile.Reason.degenerateResult,
                              "on_flat \(mode): failed with \(job.error?.code ?? "") \(job.error?.reason ?? "") (\(job.error?.message ?? ""))")
                } else {
                    try check(job.outcome == .succeeded, "on_flat \(mode): \(job.outcome?.rawValue ?? job.state.rawValue)")
                    let (_, o) = try await mesh(p, job)
                    if mode == "fail" { try check(o.bounds!.thinness >= MeshProfile.flatRatio, "on_flat fail, but a flat result was returned") }
                    await p.confirm(job)
                }
            }
            return nil
        },
        ConformanceTest("MESH-009", "Disclosure and licences: a generated mesh says ai_generated; an offer's attribution is in asset.copyright",
                        spec: "Mesh §1.11, §1.12, Base §10.2", applies: { p in offers("mesh.generate")(p) }) { p in
            let d = p.descriptor("mesh.generate")!
            var notes: [String] = []
            for m in d.models where m.namedOnly != true {
                let job = try await p.succeed(request(p, d, m))
                let (glb, _) = try await mesh(p, job)
                try check(glb.mesExtras["ai_generated"]?.boolValue == true, "\(m.id): asset.extras.mes.ai_generated isn't true (Mesh §1.11)")
                let text = try await preview(p, job)
                try check(text.contains { $0.contains("AI-generated") }, "\(m.id): the preview's comment doesn't say AI-generated (Mesh §1.11)")
                if let attribution = m.license.attribution {
                    try check(glb.asset["copyright"]?.stringValue?.contains(attribution) == true,
                              "\(m.id): asset.copyright doesn't carry the attribution \"\(attribution)\" (Mesh §1.12)")
                    try check(job.result?.provenance.model.license.attribution == attribution, "\(m.id): provenance drops the licence's attribution")
                    notes.append("\(m.id): \"\(attribution)\"")
                }
                await p.confirm(job)
            }
            return Note(notes.isEmpty ? "no offer carries an attribution" : notes.joined(separator: "; "))
        },
        ConformanceTest("MESH-010", "seed is reported; the same seed reproduces the same mesh where the offer is deterministic",
                        spec: "Mesh §1.14", applies: { p in offers(contentsOf: meshOps)(p) }) { p in
            guard let op = ["mesh.generate", "mesh.rig"].first(where: { p.descriptor($0).flatMap(defaultOffer)?.usesSeed == true }),
                  let d = p.descriptor(op), let m = defaultOffer(d) else { return Note("no Mesh offer takes a seed") }
            var r = request(p, d, m)
            r.params?[P.seed] = 7
            let a = try await p.succeed(r), b = try await p.succeed(r)
            try check(a.result?.effective[P.seed]?.intValue == 7, "\(op) doesn't report the seed it was given")
            let (ga, oa) = try await mesh(p, a), (gb, ob) = try await mesh(p, b)
            await p.confirm(a)
            await p.confirm(b)
            let same = oa.sha256 == ob.sha256 || (try? ga.facts()) == (try? gb.facts())
            if m.supports(K.deterministic)?.boolValue ?? true {
                try check(same, "\(m.id) is deterministic, but the same seed gave different meshes")
            }
            return Note("\(op) / \(m.id): the same seed gave \(oa.sha256 == ob.sha256 ? "identical files" : same ? "the same geometry" : "different meshes")")
        },
        ConformanceTest("MESH-011", "rig: geometry kept; one skin with joints and weights on every primitive; weights sum to 1; templates named; gates refuse",
                        spec: "Mesh §3.2, §4.1", applies: { p in offers("mesh.rig")(p) }) { p in
            let d = p.descriptor("mesh.rig")!
            let input = try GLB(data: p.meshFixture ?? Data()).facts()
            var notes: [String] = []
            for m in d.models where m.namedOnly != true {
                var requests: [JobRequest] = []
                let templates = list(m, K.skeletons).compactMap(\.stringValue)
                if let template = templates.first(where: { MeshProfile.joints(template: $0) != nil }) {
                    var r = request(p, d, m)
                    r.params?[P.skeleton] = .string(template)
                    requests.append(r)
                }
                if m.supports(K.autoSkeleton)?.boolValue ?? true {
                    var r = request(p, d, m)
                    r.params?[P.skeleton] = nil
                    requests.append(r)
                }
                for r in requests {
                    let job = try await p.succeed(r)
                    let (glb, o) = try await mesh(p, job)
                    let what = "\(m.id)\(r.params?[P.skeleton]?.stringValue.map { " (\($0))" } ?? " (own skeleton)")"
                    try check(o.vertices == input.vertices && o.faces == input.faces, "\(what): \(o.vertices!) vertices and \(o.faces!) faces; the input had \(input.vertices) and \(input.faces)")
                    try check(zip(o.bounds!.min + o.bounds!.max, input.bounds.min + input.bounds.max).allSatisfy { abs($0 - $1) < 1e-4 },
                              "\(what): the bounds moved (Mesh §3.2 keeps the geometry)")
                    let skins = glb.array("skins")
                    try check(skins.count == 1, "\(what): \(skins.count) skins, not one")
                    let jointNodes = skins[0]["joints"]?.arrayValue?.compactMap(\.intValue) ?? []
                    try check(o.joints == jointNodes.count, "\(what): joints \(o.joints ?? 0), the skin has \(jointNodes.count)")
                    let maxInfluences = m.supports(K.maxInfluences)?.intValue ?? 4
                    for prim in glb.primitives() {
                        guard let j = prim.attributes["JOINTS_0"], let w = prim.attributes["WEIGHTS_0"] else {
                            throw Failure("\(what): mesh \(prim.mesh) primitive \(prim.index) has no JOINTS_0 and WEIGHTS_0")
                        }
                        let weights = try glb.floats(accessor: w)
                        _ = try glb.ints(accessor: j)
                        for (v, ws) in weights.enumerated() {
                            let sum = ws.reduce(0, +)
                            try check(abs(sum - 1) <= 0.001, "\(what): vertex \(v)'s weights sum to \(sum)")
                            try check(ws.filter { $0 > 0 }.count <= maxInfluences, "\(what): vertex \(v) has more than \(maxInfluences) influences")
                        }
                    }
                    if let template = r.params?[P.skeleton]?.stringValue, let names = MeshProfile.joints(template: template) {
                        let used = jointNodes.compactMap { glb.object("nodes", $0)?["name"]?.stringValue }
                        try check(Set(used).isSubset(of: names), "\(what): joints \(Set(used).subtracting(names).sorted().prefix(3)) aren't \(template)'s")
                        let children = Set(jointNodes.flatMap { glb.object("nodes", $0)?["children"]?.arrayValue?.compactMap(\.intValue) ?? [] })
                        let roots = jointNodes.filter { !children.contains($0) }.compactMap { glb.object("nodes", $0)?["name"]?.stringValue }
                        try check(roots == [names[0]], "\(what): the skeleton's root is \(roots), not \(names[0])")
                    }
                    notes.append("\(what): \(o.joints!) joints")
                    await p.confirm(job)
                }
                if m.supports(K.autoSkeleton)?.boolValue == false {
                    var bad = request(p, d, m)
                    bad.params?[P.skeleton] = nil
                    try await refuse(p, bad, 422, "unsupported_parameter", "no skeleton to \(m.id), which needs one")
                    notes.append("\(m.id) refused a request without a skeleton")
                }
                if let value = d.params["properties"]?[P.skeleton]?["enum"]?.arrayValue?.first(where: { !list(m, K.skeletons).contains($0) }) {
                    var bad = request(p, d, m)
                    bad.params?[P.skeleton] = value
                    try await refuse(p, bad, 422, "unsupported_parameter", "skeleton \(value) to \(m.id), which doesn't list it")
                }
            }
            return Note(notes.joined(separator: "; "))
        },
        ConformanceTest("MESH-012", "rig input: a GLB with an embedded texture is accepted; bytes that aren't a GLB are input_invalid",
                        spec: "Mesh §1.1, §3.2", applies: { p in offers("mesh.rig")(p) }) { p in
            let d = p.descriptor("mesh.rig")!
            guard let m = defaultOffer(d) else { throw Failure("mesh.rig has no default offer") }
            let good = try await p.succeed(request(p, d, m, named: false))
            await p.confirm(good)
            var bad = request(p, d, m, named: false)
            bad.inputs?[MeshProfile.Input.mesh] = meshInput(Fixtures.png())
            let reply = try await p.wire.json("POST", "jobs", bad)
            if reply.status == 201 {
                let job = try await p.settle(try reply.decode(Job.self))
                try check(job.outcome == .failed && job.error?.code == "input_invalid",
                          "a PNG sent as a GLB ended \(job.outcome?.rawValue ?? job.state.rawValue) \(job.error?.code ?? ""), not failed input_invalid")
            } else {
                try expect(reply, 422, code: "input_invalid", "a PNG sent as a GLB", schemas: p.schemas)
            }
            return nil
        },
    ]
}
