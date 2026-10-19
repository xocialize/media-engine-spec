import Foundation
import MESCore

/// The Image profile 0.1 tests (IMAGE-nnn, spec/profiles/image.md §5), for the operations the engine offers.
enum ImageTests {
    static func offers(_ ops: String...) -> @Sendable (Probe) -> String? {
        { p in
            guard p.info.profiles.contains(where: { $0.id == ImageProfile.id }) else { return "the engine doesn't offer the Image profile" }
            return ops.contains { p.descriptor($0) != nil } ? nil : "the engine offers none of \(ops.joined(separator: ", "))"
        }
    }

    /// Image operations whose image output keeps the input's size (the profile table's `keeps_input_size`), excluding
    /// ones the suite can't drive.
    static func sizeKeeping(_ p: Probe) -> [Descriptor] {
        p.operations.filter { d in
            d.profile == ImageProfile.id && ImageProfile.operations.operations[d.operation]?.keepsInputSize == true
                && d.outputs.contains { $0.kind == .image || $0.kind == .mask } && p.minimalRequest(d) != nil
                && d.inputs.contains { $0.kind == .image && $0.required }
        }
    }

    static func withImage(_ p: Probe, _ d: Descriptor, _ image: Data, mediaType: String = "image/png") -> JobRequest {
        var request = p.minimalRequest(d)!
        let name = d.inputs.first { $0.kind == .image && $0.required }!.name
        request.inputs?[name] = .one(.inline(mediaType: mediaType, data: image))
        return request
    }

    static let all: [ConformanceTest] = [
        ConformanceTest("IMAGE-001", "fill and erase keep black-mask pixels byte-identical", spec: "Image §1.7",
                        applies: offers("image.fill", "image.erase")) { p in
            for op in ["image.fill", "image.erase"] {
                guard let d = p.descriptor(op), let request = p.minimalRequest(d) else { continue }
                let job = try await p.succeed(request)
                let (_, data) = try await p.output(job)
                let out = try DecodedImage(data), src = try DecodedImage(Fixtures.png())
                try check(out.width == src.width && out.height == src.height, "\(op) changed the size to \(out.width)×\(out.height)")
                for y in 0..<src.height {
                    for x in 0..<(src.width / 2) where out.pixel(x, y) != src.pixel(x, y) {
                        throw Failure("\(op): the black-mask pixel (\(x), \(y)) changed from \(src.pixel(x, y)) to \(out.pixel(x, y))")
                    }
                }
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("IMAGE-002", "upscale returns exactly input size × scale, for each scale offered", spec: "Image §3",
                        applies: offers("image.upscale")) { p in
            let d = p.descriptor("image.upscale")!
            let schema = d.params["properties"]?["scale"]
            var scales = schema?["enum"]?.arrayValue?.compactMap(\.intValue) ?? []
            if scales.isEmpty, let lo = schema?["minimum"]?.intValue, let hi = schema?["maximum"]?.intValue { scales = Array(lo...min(hi, 4)) }
            if scales.isEmpty { scales = [2] }
            for scale in scales {
                var request = withImage(p, d, Fixtures.png(width: 40, height: 24))
                request.params = ["scale": .number(Double(scale))]
                let job = try await p.succeed(request)
                let out = try DecodedImage(try await p.output(job).1)
                try check(out.width == 40 * scale && out.height == 24 * scale, "×\(scale) gave \(out.width)×\(out.height), not \(40 * scale)×\(24 * scale)")
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("IMAGE-003", "Image operations keep the input size (except upscale and extend)", spec: "Image §1.8, §3",
                        applies: { p in sizeKeeping(p).isEmpty ? "no size-keeping image operation is offered" : nil }) { p in
            for d in sizeKeeping(p) {
                let job = try await p.succeed(withImage(p, d, Fixtures.png(width: 72, height: 40)))
                for output in job.result!.outputs where output.kind == .image || output.kind == .mask {
                    let out = try DecodedImage(try await p.output(job, output.index).1)
                    try check(out.width == 72 && out.height == 40, "\(d.operation) output \(output.name) is \(out.width)×\(out.height), not 72×40")
                }
                await p.confirm(job)
            }
            return nil
        },
        ConformanceTest("IMAGE-004", "matte masks are 8-bit grey; extract carries alpha", spec: "Image §1.5, §1.6",
                        applies: offers("image.matte")) { p in
            let d = p.descriptor("image.matte")!
            var request = withImage(p, d, Fixtures.png())
            let declared = d.params["properties"]?["outputs"] != nil
            if declared { request.params = ["outputs": ["mask", "extract"]] }
            let job = try await p.succeed(request)
            for output in job.result!.outputs {
                let image = try DecodedImage(try await p.output(job, output.index).1)
                if output.name == "mask" || output.kind == .mask {
                    try check(image.isGrey && image.bitsPerComponent == 8, "the mask is \(image.bitsPerComponent)-bit \(image.isGrey ? "grey" : "colour")")
                } else if output.name == "extract" {
                    try check(image.hasAlpha, "extract has no alpha")
                }
            }
            await p.confirm(job)
            return nil
        },
        ConformanceTest("IMAGE-005", "EXIF orientation is applied; outputs are upright with no rotation flag", spec: "Image §1.4",
                        applies: { p in sizeKeeping(p).isEmpty ? "no size-keeping image operation is offered" : nil }) { p in
            let d = sizeKeeping(p)[0]
            let job = try await p.succeed(withImage(p, d, Fixtures.orientedJPEG(storedWidth: 64, storedHeight: 32), mediaType: "image/jpeg"))
            let out = try DecodedImage(try await p.output(job).1)
            try check(out.width == 32 && out.height == 64, "\(d.operation) on a 64×32 JPEG with orientation 6 gave \(out.width)×\(out.height), not 32×64")
            try check(out.orientation == 1, "the output carries EXIF orientation \(out.orientation); outputs are upright with none")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("IMAGE-006", "A non-sRGB input is converted: a color_converted warning and an output tagged sRGB", spec: "Image §1.3, §4",
                        applies: { p in sizeKeeping(p).isEmpty ? "no size-keeping image operation is offered" : nil }) { p in
            let d = sizeKeeping(p)[0]
            let job = try await p.succeed(withImage(p, d, Fixtures.displayP3PNG()))
            try check(job.warnings.contains { $0.code == ImageProfile.WarningCode.colorConverted },
                      "no color_converted warning (warnings: \(job.warnings.map(\.code)))")
            let out = try DecodedImage(try await p.output(job).1)
            try check(out.profile?.localizedCaseInsensitiveContains("sRGB") == true, "the output is tagged \(out.profile ?? "with no profile"), not sRGB")
            await p.confirm(job)
            return nil
        },
        ConformanceTest("IMAGE-007", "The seed is reported, and the same seed reproduces the result", spec: "Image §2",
                        applies: { p in
                            p.operations.contains { $0.params["properties"]?["seed"] != nil && p.minimalRequest($0) != nil }
                                ? nil : "no operation takes a seed"
                        }) { p in
            let d = p.operations.first { $0.params["properties"]?["seed"] != nil && p.minimalRequest($0) != nil }!
            var request = p.minimalRequest(d)!
            request.params = ["seed": 4242]
            let a = try await p.succeed(request), b = try await p.succeed(request)
            try check(a.result?.provenance.seed == 4242, "provenance.seed is \(a.result?.provenance.seed.map(String.init) ?? "missing"), not 4242")
            let same = a.result?.outputs.first?.sha256 == b.result?.outputs.first?.sha256
            await p.confirm(a)
            await p.confirm(b)
            return same ? nil : Note("\(d.operation) isn't deterministic for a fixed seed (allowed where the model isn't).")
        },
        ConformanceTest("IMAGE-008", "size and aspect together are refused with 400", spec: "Image §2",
                        applies: { p in
                            p.operations.contains { $0.params["properties"]?["size"] != nil && $0.params["properties"]?["aspect"] != nil }
                                ? nil : "no operation takes both size and aspect"
                        }) { p in
            let d = p.operations.first { $0.params["properties"]?["size"] != nil && $0.params["properties"]?["aspect"] != nil }!
            guard var request = p.minimalRequest(d) else { throw Failure("can't build a request for \(d.operation)") }
            request.params = ["size": ["width": 512, "height": 512], "aspect": "16:9"]
            try expect(try await p.wire.json("POST", "jobs", request), 400, code: "invalid_request", "size with aspect", schemas: p.schemas)
            return nil
        },
        ConformanceTest("IMAGE-009", "Descriptors match the profile table: required inputs and outputs, of the right kinds", spec: "Image §3, §5",
                        applies: offers(contentsOf: Array(ImageProfile.operations.operations.keys))) { p in
            for d in p.operations where d.profile == ImageProfile.id {
                guard let spec = ImageProfile.operations.operations[d.operation] else {
                    throw Failure("\(d.operation) isn't an Image 0.1 operation")
                }
                for (name, io) in spec.inputs where io.required == true {
                    guard let input = d.inputs.first(where: { $0.name == name }) else { throw Failure("\(d.operation) lacks input \(name)") }
                    try check(input.kind == io.kind, "\(d.operation).\(name) is \(input.kind.rawValue), the profile says \(io.kind.rawValue)")
                }
                for (name, io) in spec.outputs {
                    guard let output = d.outputs.first(where: { $0.name == name }) else { throw Failure("\(d.operation) lacks output \(name)") }
                    try check(output.kind == io.kind, "\(d.operation) output \(name) is \(output.kind.rawValue), the profile says \(io.kind.rawValue)")
                }
                let required = Set(d.params["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                let vocabulary = Set(spec.vocabulary)
                try check(required.isSubset(of: vocabulary),
                          "\(d.operation) requires parameters outside the vocabulary: \(required.subtracting(vocabulary).sorted())")
            }
            return nil
        },
        ConformanceTest("IMAGE-010", "An output the operation doesn't offer is refused with 422 unsupported_parameter", spec: "Image §1.2",
                        applies: { p in unofferedOutput(p) == nil ? "every operation offers every output in the vocabulary" : nil }) { p in
            let (d, output) = unofferedOutput(p)!
            guard var request = p.minimalRequest(d) else { throw Failure("can't build a request for \(d.operation)") }
            request.params = (request.params ?? [:]).merging(["output": output]) { _, new in new }
            try expect(try await p.wire.json("POST", "jobs", request), 422, code: "unsupported_parameter",
                       "an output \(d.operation) doesn't offer (\(output))", schemas: p.schemas)
            return nil
        },
        ConformanceTest("IMAGE-011", "enhance_prompt returns enhanced data with prompt and applied, for a target model the target operation offers",
                        spec: "Image §3.1", applies: offers("image.enhance_prompt")) { p in
            let d = p.descriptor("image.enhance_prompt")!
            guard var request = p.minimalRequest(d) else { throw Failure("can't build a request for image.enhance_prompt") }
            let typed = "a lighthouse on a cliff at dusk"
            request.inputs?["prompt"] = .text(typed)
            if d.params["properties"]?["seed"] != nil { request.params = ["seed": 7] }
            let job = try await p.succeed(request)
            guard let output = job.result?.outputs.first(where: { $0.name == "enhanced" }) else {
                throw Failure("no output named enhanced (outputs: \(job.result?.outputs.map(\.name) ?? []))")
            }
            try check(output.kind == .data, "enhanced is \(output.kind.rawValue), not data")
            let value: JSONValue
            if let inline = output.value { value = inline } else {
                value = try MESJSON.decoder.decode(JSONValue.self, from: try await p.output(job, output.index).1)
            }
            try p.schemas.require(value, "profiles/image/vocabulary.schema.json#/$defs/enhanced_prompt", "enhanced")
            if value["applied"]?.boolValue == false {
                try check(value["prompt"]?.stringValue == typed, "applied is false but the prompt changed")
                try check(job.warnings.contains { $0.code == ImageProfile.WarningCode.promptEnhanceIgnored },
                          "applied is false without a prompt_enhance_ignored warning")
            }
            let effective = job.result?.effective ?? [:]
            let target = effective[ImageProfile.Param.targetOperation]?.stringValue ?? "image.generate"
            if let model = effective[ImageProfile.Param.targetModel]?.stringValue, let targetDescriptor = p.descriptor(target) {
                try check(targetDescriptor.models.contains { $0.id == model }, "effective.target_model \(model) isn't an offer of \(target)")
            } else if effective[ImageProfile.Param.targetModel] == nil {
                throw Failure("effective.target_model doesn't name the model the rewrite was made for")
            }
            await p.confirm(job)
            return nil
        },
        ConformanceTest("IMAGE-012", "With prompt_enhance off the text goes as typed: no prompt_rewritten unless prompt_enhance_ignored says why",
                        spec: "Image §1.9", applies: { p in enhanceable(p) == nil ? "no operation the suite can drive declares prompt_enhance" : nil }) { p in
            let (d, base, input) = enhanceable(p)!
            let typed = "a lighthouse on a cliff at dusk"
            var request = base
            request.inputs?[input] = .text(typed)
            request.params = [ImageProfile.Param.promptEnhance: "off"]
            let off = try await p.succeed(request)
            let codes = off.warnings.map(\.code)
            if codes.contains(ImageProfile.WarningCode.promptRewritten) {
                try check(codes.contains(ImageProfile.WarningCode.promptEnhanceIgnored),
                          "\(d.operation) with prompt_enhance off rewrote the \(input) without saying why (prompt_enhance_ignored)")
            } else if let used = off.result?.effective[input]?.stringValue {
                try check(used == typed, "with prompt_enhance off, effective.\(input) is \(used), not the text as typed")
            }
            await p.confirm(off)
            let modes = d.params["properties"]?[ImageProfile.Param.promptEnhance]?["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard modes.contains("on") else { return nil }
            request.params = [ImageProfile.Param.promptEnhance: "on"]
            let on = try await p.succeed(request)
            await p.confirm(on)
            guard let rewritten = on.warnings.first(where: { $0.code == ImageProfile.WarningCode.promptRewritten }) else { return nil }
            try check(rewritten.param == input, "prompt_rewritten names \(rewritten.param ?? "no input"), not \(input)")
            for helper in on.result?.provenance.helpers ?? [] {
                try check(!helper.role.isEmpty, "a helper without a role")
            }
            return on.result?.effective[input] == nil
                ? Note("\(d.operation) rewrote the \(input) without reporting the text in effective.\(input) (SHOULD, Image §1.9).") : nil
        },
        ConformanceTest("IMAGE-013", "An ic adapter's required slots are counted: too few references or images is 400", spec: "Image §1.10",
                        applies: { p in slotted(p) == nil ? "no operation the suite can drive offers an ic adapter on generate or edit" : nil }) { p in
            let (d, base, model, adapter, input, needed) = slotted(p)!
            var request = base
            request.model = model.id
            request.adapters = [AdapterRequest(id: adapter.id)]
            let image = RequestInput.one(.inline(mediaType: "image/png", data: Fixtures.png()))
            let short = needed - 1
            request.inputs?[input] = short == 0 ? nil : .many(Array(repeating: image.values[0], count: short))
            try expect(try await p.wire.json("POST", "jobs", request), 400, code: "invalid_request",
                       "\(adapter.id) with \(short) of its \(needed) slots in \(input)", schemas: p.schemas)
            request.inputs?[input] = .many(Array(repeating: image.values[0], count: needed))
            let job = try await p.succeed(request)
            try check(job.result?.provenance.adapters?.map(\.id) == [adapter.id], "provenance doesn't list \(adapter.id)")
            await p.confirm(job)
            return nil
        },
    ]

    /// An operation the suite can drive that declares `prompt_enhance` with `off`, and its text input.
    static func enhanceable(_ p: Probe) -> (Descriptor, JobRequest, String)? {
        for d in p.operations where d.profile == ImageProfile.id {
            guard let modes = d.params["properties"]?[ImageProfile.Param.promptEnhance]?["enum"]?.arrayValue?.compactMap(\.stringValue),
                  modes.contains("off"), let request = p.minimalRequest(d),
                  let input = ["prompt", "instruction"].first(where: { name in d.inputs.contains { $0.name == name && $0.kind == .text } })
            else { continue }
            return (d, request, input)
        }
        return nil
    }

    /// An `ic` adapter on generate or edit whose slots the suite can leave one short: the operation, a minimal request,
    /// the offer, the adapter, the input its slots fill and how many required slots it has.
    static func slotted(_ p: Probe) -> (Descriptor, JobRequest, ModelOffer, AdapterOffer, String, Int)? {
        for d in p.operations where d.profile == ImageProfile.id {
            guard let input = ImageProfile.operations.operations[d.operation]?.adapterInput,
                  let spec = d.inputs.first(where: { $0.name == input }), let request = p.minimalRequest(d) else { continue }
            let floor = spec.required ? max(1, spec.min ?? 1) : (spec.min ?? 0)
            for m in d.models {
                for a in m.adapters ?? [] where a.kind == .ic && a.requiredSlots - 1 >= floor && a.requiredSlots <= (spec.max ?? .max) {
                    return (d, request, m, a, input, a.requiredSlots)
                }
            }
        }
        return nil
    }

    /// An Image operation whose `output` narrows the vocabulary, and a value it leaves out: bit depth 16, else a media type.
    static func unofferedOutput(_ p: Probe) -> (Descriptor, JSONValue)? {
        let mediaTypes = ["image/png", "image/jpeg", "image/heic", "image/webp", "image/tiff"]
        for d in p.operations where d.profile == ImageProfile.id && p.minimalRequest(d) != nil {
            guard let output = d.params["properties"]?["output"]?["properties"] else { continue }
            if let depths = output["bit_depth"]?["enum"]?.arrayValue?.compactMap(\.intValue), !depths.contains(16) {
                return (d, ["bit_depth": 16])
            }
            if let offered = output["media_type"]?["enum"]?.arrayValue?.compactMap(\.stringValue),
               let missing = mediaTypes.first(where: { !offered.contains($0) }) {
                return (d, ["media_type": .string(missing)])
            }
        }
        return nil
    }

    static func offers(contentsOf ops: [String]) -> @Sendable (Probe) -> String? {
        { p in ops.contains { p.descriptor($0) != nil } ? nil : "the engine offers no Image operations" }
    }
}

/// The whole catalogue, in run order. BASE-090 runs last: it revokes the suite's pairing.
public enum Catalogue {
    public static let version = "0.1"

    public static var all: [ConformanceTest] {
        let base = BaseTests.all
        return base.filter { $0.id != "BASE-090" } + ImageTests.all + base.filter { $0.id == "BASE-090" }
    }

    /// The catalogue as Markdown (docs/CONFORMANCE.md): engine tests, then client tests.
    public static var markdown: String {
        var lines = ["## Engine tests", "", "| Test | Checks | Spec |", "|---|---|---|"]
        for t in all.sorted(by: { $0.id < $1.id }) { lines.append("| \(t.id) | \(t.title) | \(t.spec) |") }
        lines += ["", "## Client tests", "",
                  "Each runs against a scenario-mode mock engine; the scenario is what the engine does to the client.", "",
                  "| Test | Checks | Spec | Scenario |", "|---|---|---|---|", ClientChecks.markdown]
        return lines.joined(separator: "\n") + "\n"
    }
}
