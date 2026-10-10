import Foundation
import MESClientKit
import MESCore
import MESEngineCore
@testable import MESFormsUI
import MESInProcess
@testable import MockEngineCore
import Testing

// MESFormsUI's model layer: widgets resolved from every mock descriptor, values by path, validation mapped to fields,
// and — the point of the package — requests that the engine accepts, run through the in-process mock.

func mockDescriptors() async -> [Descriptor] { await MockImageEngine().descriptors() }

func descriptor(_ op: String) async -> Descriptor { await mockDescriptors().first { $0.operation == op }! }

func field(_ fields: [FormField], _ name: String) -> FormField { fields.first { $0.name == name }! }

func allFields(_ fields: [FormField]) -> [FormField] {
    fields.flatMap { f -> [FormField] in
        switch f.widget {
        case .object(let children): [f] + allFields(children)
        case .choice(let variants): [f] + variants.flatMap { allFields($0.fields) }
        default: [f]
        }
    }
}

func png(_ width: Int, _ height: Int, grey: Bool = false) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    if grey {
        try Raster.writeGreyPNG((0..<(width * height)).map { $0 % width < width / 2 ? 0 : 255 }, width: width, height: height, to: url)
    } else {
        var r = Raster(width: width, height: height)
        for y in 0..<height { for x in 0..<width { r[x, y] = (UInt8(x * 4), UInt8(y * 4), 128, 255) } }
        try r.writePNG(to: url)
    }
    return url
}

func engineConfig() -> EngineConfiguration {
    let spool = FileManager.default.temporaryDirectory.appendingPathComponent("mes-forms-\(UUID().uuidString)")
    var c = EngineConfiguration(id: "eng_forms", name: "Forms", implementationName: "mes-mock-engine",
                                implementationVersion: "0.1.0", spoolDirectory: spool)
    c.advertise = false
    return c
}

@Suite("MESFormsUI: widgets from descriptors")
@MainActor
struct WidgetTests {
    @Test("Every field of every mock descriptor (and its extension) gets a real widget, not the JSON fallback")
    func everyFieldHasAWidget() async {
        var count = 0
        for d in await mockDescriptors() {
            var fields = OperationFormModel(descriptor: d).fields
            for ext in d.extensions ?? [] { fields += FormSchema.fields(of: ext.schema) }
            for f in allFields(fields) {
                count += 1
                #expect(f.widget != .json, "\(d.operation).\(f.name) fell back to JSON")
            }
        }
        #expect(count > 40)
    }

    @Test("Hints pick the widget; the schema bounds it")
    func widgets() async {
        let generate = OperationFormModel(descriptor: await descriptor("image.generate")).fields
        #expect(field(generate, "quality").widget == .picker(["draft", "standard", "best"]))
        #expect(field(generate, "count").widget == .stepper(1...8))
        #expect(field(generate, "seed").widget == .seed)
        #expect(field(generate, "size").widget == .size(minimum: 16))
        #expect(field(generate, "aspect").widget == .aspect)
        #expect(field(generate, "megapixels").widget == .slider(0.25...16, integer: false))
        #expect(field(generate, "negative_prompt").widget == .textarea)
        guard case .object(let output) = field(generate, "output").widget else { Issue.record("output"); return }
        #expect(output.map(\.name) == ["bit_depth", "media_type"])
        #expect(field(output, "bit_depth").widget == .picker([8, 16]))

        let extend = OperationFormModel(descriptor: await descriptor("image.extend")).fields
        guard case .choice(let variants) = field(extend, "canvas").widget else { Issue.record("canvas"); return }
        #expect(variants.map(\.title) == ["Left · Top · Right · Bottom", "Size · Anchor"])
        #expect(field(variants[1].fields, "size").widget == .size(minimum: 16))

        let matte = OperationFormModel(descriptor: await descriptor("image.matte")).fields
        #expect(field(matte, "outputs").widget == .multiPicker(["mask", "extract"]))
        let ext = try! #require(await descriptor("image.generate").extensions?.first)
        let extFields = FormSchema.fields(of: ext.schema)
        #expect(extFields.map(\.widget) == [.slider(0...1, integer: false), .toggle, .color])
    }

    @Test("Order and advanced follow the hints; labels read as words")
    func orderAndLabels() async {
        let form = OperationFormModel(descriptor: await descriptor("image.generate"))
        #expect(form.mainFields.map(\.name) == ["size", "aspect", "quality", "count"], "by the order hints")
        #expect(Set(form.advancedFields.map(\.name)) == ["negative_prompt", "seed", "output", "megapixels"])
        #expect(OperationFormModel.grouped(form.mainFields).map(\.group) == [nil])
        #expect(FormSchema.label("negative_prompt") == "Negative prompt")
        #expect(FormSchema.display("golden_hour") == "Golden hour" && FormSchema.display("image/png") == "image/png")
        #expect(FormSchema.display(16) == "16" && FormSchema.display(0.75) == "0.75")
        #expect(FormSchema.display(.number(4_716_241_010_020_292)) == "4716241010020292", "seeds use the whole 2^53 range")
        #expect(FormSchema.hex(1, 0.5, 0) == "#ff8000" && FormSchema.rgb("#ff8000")! == (1, 128.0 / 255, 0))
    }
}

@Suite("MESFormsUI: values, validation and requests")
@MainActor
struct FormModelTests {
    @Test("Values by path: nested objects appear and disappear; issues map to their top-level field")
    func pathsAndIssues() async {
        let form = OperationFormModel(descriptor: await descriptor("image.fill"))
        #expect(form.request().params == nil, "an untouched form sends no params")
        form.setValue(2, at: ["strength"])
        #expect(form.issues["strength"] != nil)
        form.setValue(0.4, at: ["strength"])
        form.setValue(12, at: ["output", "bit_depth"])
        #expect(form.issues["output"] != nil && form.issues["strength"] == nil)
        form.setValue(16, at: ["output", "bit_depth"])
        #expect(form.issues.isEmpty)
        #expect(form.request().params == ["strength": 0.4, "output": ["bit_depth": 16]])
        form.setValue(nil, at: ["output", "bit_depth"])
        #expect(form.values["output"] == nil, "clearing the last nested value removes the object")
        form.reset()
        #expect(form.values.isEmpty)
    }

    @Test("oneOf variants start valid; extensions start from their defaults; policy excludes models")
    func variantsExtensionsPolicy() async throws {
        let extend = await descriptor("image.extend")
        guard case .choice(let variants) = FormSchema.fields(of: extend.params).first(where: { $0.name == "canvas" })?.widget else {
            Issue.record("canvas"); return
        }
        for v in variants {
            let value = FormSchema.initialValue(v.schema)
            #expect(SchemaValidator().validate(value, against: v.schema).isEmpty, "\(v.title): \(value)")
            #expect(FormSchema.variantIndex(of: value, in: variants) == v.id)
        }

        let generate = OperationFormModel(descriptor: await descriptor("image.generate"))
        let ext = try #require(generate.descriptor.extensions?.first)
        generate.setEnabled(ext, true)
        #expect(generate.extensions[ext.name] == ["amount": 0.2, "monochrome": false, "tint": "#d9c7a3"])
        generate.setExtensionValue(ext, "red", at: ["tint"])
        #expect(generate.issues[ext.name] != nil)
        generate.setExtensionValue(ext, "#336699", at: ["tint"])
        #expect(generate.issues.isEmpty)

        #expect(generate.effectiveModel?.id == "mock")
        let research = try #require(generate.descriptor.models.first { $0.id == "mock-research" })
        #expect(!generate.isExcluded(research))
        generate.policy.license = .commercialUse
        #expect(generate.isExcluded(research))
        #expect(generate.request().policy == Policy(license: .commercialUse))
        #expect(generate.missingInputs(media: []).map(\.name) == ["prompt"])
    }

    @Test("Every mock descriptor's default form makes a request the engine accepts and runs")
    func defaultFormsRun() async throws {
        let engine = try await InProcessEngine.start(engine: MockImageEngine(), configuration: engineConfig())
        let image = try png(32, 32)
        let mask = try png(32, 32, grey: true)
        var ran: [String] = []
        for d in await mockDescriptors() {
            let form = OperationFormModel(descriptor: d)
            for spec in form.textInputs { form.text[spec.name] = "a lighthouse" }
            var media: [String: RequestInput] = [:]
            for spec in form.mediaInputs where spec.kind == .image || spec.kind == .mask {
                let upload = try await engine.upload(contentsOf: spec.kind == .mask ? mask : image, mediaType: "image/png")
                media[spec.name] = .one(.upload(upload.uploadID))
            }
            #expect(form.missingInputs(media: Set(media.keys)).isEmpty, "\(d.operation)")
            let job = try await engine.run(form.request(media: media))
            #expect(job.outcome == .succeeded, "\(d.operation): \(String(describing: job.error))")
            if job.outcome == .succeeded { ran.append(d.operation) }
            _ = try? await engine.confirm(job.id)
        }
        #expect(ran.count == 13)
        await engine.stop()
    }

    @Test("Edited values, a chosen variant and an extension reach the engine")
    func editedFormsRun() async throws {
        let engine = try await InProcessEngine.start(engine: MockImageEngine(), configuration: engineConfig())
        let generate = OperationFormModel(descriptor: await descriptor("image.generate"))
        generate.text["prompt"] = "a fox"
        generate.setValue(["width": 64, "height": 48], at: ["size"])
        generate.setValue(7, at: ["seed"])
        generate.setValue("best", at: ["quality"])
        let ext = try #require(generate.descriptor.extensions?.first)
        generate.setEnabled(ext, true)
        generate.setExtensionValue(ext, 0.5, at: ["amount"])
        let job = try await engine.run(generate.request())
        #expect(job.outcome == .succeeded && job.result?.outputs.first?.width == 64)
        #expect(job.result?.provenance.seed == 7)
        #expect(job.result?.effective["extensions"]?["x-mock.grain"]?["amount"] == 0.5)

        let extend = OperationFormModel(descriptor: await descriptor("image.extend"))
        guard case .choice(let variants) = extend.fields.first(where: { $0.name == "canvas" })?.widget else { return }
        extend.setValue(FormSchema.initialValue(variants[0].schema), at: ["canvas"])
        extend.setValue(8, at: ["canvas", "left"])
        extend.setValue(8, at: ["canvas", "right"])
        let upload = try await engine.upload(contentsOf: try png(32, 32), mediaType: "image/png")
        let extended = try await engine.run(extend.request(media: ["image": .one(.upload(upload.uploadID))]))
        #expect(extended.outcome == .succeeded && extended.result?.outputs.first?.width == 48, "\(String(describing: extended.error))")
        await engine.stop()
    }
}
