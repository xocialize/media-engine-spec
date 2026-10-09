import Foundation
import MESCore
import MESEngineCore

/// A mock Image-profile engine (MES R0b). It offers all 13 operations with synthetic results that obey the profile's
/// rules: fill and erase keep black-mask pixels byte-identical, upscale is exactly ×scale, mattes are 8-bit grey,
/// and the same seed gives the same result. Clients and the conformance suite test against it; it runs no model.
public struct MockImageEngine: MediaEngine {
    /// Delay per progress step, to exercise waiting, progress and cancellation.
    public var stepDelay: Duration
    public var steps: Int

    public init(stepDelay: Duration = .zero, steps: Int = 4) {
        self.stepDelay = stepDelay
        self.steps = steps
    }

    static let mockLicense = License.apache2
    static let researchLicense = License(spdx: "LicenseRef-Mock-Research", commercialUse: .no,
                                         notice: "A stand-in for research-only weights.", acceptedRequired: true)

    // MARK: - Descriptors

    public func descriptors() async -> [Descriptor] {
        ImageProfile.operations.operations.keys.sorted().map(Self.descriptor)
    }

    static func descriptor(_ operation: String) -> Descriptor {
        let spec = ImageProfile.operations.operations[operation]!
        let imageTypes = ["image/png", "image/jpeg", "image/heic", "image/webp", "image/tiff"]
        let inputs = spec.inputs.sorted { $0.key < $1.key }.map { name, io in
            InputSpec(name: name, kind: io.kind, required: io.required ?? false,
                      max: io.kind == .text || io.kind == .data ? nil : (name == "references" || name == "images" ? 4 : 1),
                      mediaTypes: io.kind == .image ? imageTypes : io.kind == .mask ? ["image/png"] : nil)
        }
        var properties: [String: JSONValue] = [:]
        for (order, name) in spec.vocabulary.enumerated() {
            guard case .object(var schema)? = ImageProfile.vocabularySchema(name, operation: operation) else { continue }
            schema["x-mes-ui"] = .object(ui(name, order: order))
            properties[name] = .object(schema)
        }
        if operation == "image.relight" {
            properties[ImageProfile.Param.preset] = ["enum": ["soft", "golden_hour", "studio"],
                                                     "x-mes-ui": ["label": "Preset", "widget": "picker"]]
        }
        let outputs = spec.outputs.sorted { $0.key < $1.key }.map { name, io in
            OutputSpec(name: name, kind: io.kind, mediaTypes: io.kind == .data ? ["application/json"] : ["image/png"],
                       min: name == "images" || name == "masks" ? 1 : (operation == "image.matte" ? 0 : 1),
                       max: name == "images" || name == "masks" ? 8 : 1)
        }
        var models = [ModelOffer(id: "mock", title: "Mock \(operation)", license: mockLicense, memoryClass: .small,
                                 speedClass: .fast, qualityTiers: [.draft, .standard, .best], isDefault: true)]
        if operation == "image.generate" {
            models.append(ModelOffer(id: "mock-research", title: "Mock research model", license: researchLicense,
                                     memoryClass: .large, speedClass: .slow, qualityTiers: [.best]))
        }
        return Descriptor(
            operation: operation, profile: ImageProfile.id, profileVersion: ImageProfile.version,
            title: title(operation), summary: "Mock: synthetic results that follow the Image profile's rules.",
            inputs: inputs,
            params: .object(["type": "object", "additionalProperties": false, "properties": .object(properties)]),
            outputs: outputs, limits: .init(maxWidth: 8192, maxHeight: 8192, maxMegapixels: 16, maxCount: 8),
            qualityTiers: [.draft, .standard, .best], models: models,
            extensions: operation == "image.generate" ? [grainExtension] : nil, remote: .init(possible: false))
    }

    /// A vendor extension (Base §6.2) on `image.generate`, so clients and form renderers have one to exercise. The
    /// mock records it in `effective.extensions` and otherwise ignores it.
    static let grainExtension = ExtensionSpec(name: "x-mock.grain", title: "Film grain", schema: [
        "type": "object", "additionalProperties": false,
        "properties": [
            "amount": ["type": "number", "minimum": 0, "maximum": 1, "default": 0.2,
                       "x-mes-ui": ["label": "Amount", "widget": "slider", "order": 0]],
            "monochrome": ["type": "boolean", "default": false, "x-mes-ui": ["label": "Monochrome", "order": 1]],
            "tint": ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$", "default": "#d9c7a3",
                     "x-mes-ui": ["label": "Tint", "widget": "color", "order": 2, "help": "The grain's colour."]],
        ],
    ])

    static func title(_ op: String) -> String {
        ["image.generate": "Generate", "image.edit": "Edit", "image.fill": "Generative fill", "image.erase": "Erase",
         "image.extend": "Extend canvas", "image.upscale": "Upscale", "image.restore": "Restore", "image.relight": "Relight",
         "image.colorize": "Colorize", "image.matte": "Select subject", "image.segment": "Select by prompt",
         "image.describe": "Describe", "image.score": "Quality score"][op] ?? op
    }

    static func ui(_ name: String, order: Int) -> [String: JSONValue] {
        let widgets: [String: String] = ["prompt": "textarea", "negative_prompt": "textarea", "seed": "seed", "quality": "picker",
                                         "size": "size", "aspect": "aspect", "megapixels": "slider", "strength": "slider",
                                         "count": "stepper", "scale": "picker", "content": "picker", "kind": "picker",
                                         "outputs": "picker", "language": "text"]
        var hints: [String: JSONValue] = ["label": .string(name.replacingOccurrences(of: "_", with: " ").capitalized),
                                          "order": .number(Double(order))]
        if let w = widgets[name] { hints["widget"] = .string(w) }
        if ["seed", "negative_prompt", "output", "megapixels"].contains(name) { hints["advanced"] = true }
        return hints
    }

    // MARK: - Running

    public func run(_ context: RunContext) async throws -> RunOutput {
        for step in 1...max(1, steps) {
            try Task.checkCancellation()
            if stepDelay > .zero { try await Task.sleep(for: stepDelay) }
            await context.reporter.progress(.running, step: step, steps: max(1, steps))
        }
        try Task.checkCancellation()
        let seed = context.param("seed")?.intValue ?? Int.random(in: 0...999_999)
        var warnings: [Warning] = []
        let out = context.outputDirectory
        func png(_ raster: Raster, _ name: String, _ i: Int = 0) throws -> ProducedOutput {
            let url = out.appendingPathComponent("\(name)-\(i).png")
            try raster.writePNG(to: url)
            return .file(url, name: name, kind: .image, mediaType: "image/png", width: raster.width, height: raster.height)
        }
        func loadImage(_ name: String) throws -> Raster {
            guard let url = context.input(name)?.fileURL else { throw MESError(.invalidRequest, "Input '\(name)' is missing.", param: name) }
            let (raster, converted) = try Raster.load(url)
            if converted {
                warnings.append(Warning(code: ImageProfile.WarningCode.colorConverted, message: "Input '\(name)' was converted to sRGB.",
                                        param: name))
            }
            return raster
        }
        func loadMask(for image: Raster) throws -> [UInt8] {
            guard let url = context.input("mask")?.fileURL else { throw MESError(.invalidRequest, "Input 'mask' is missing.", param: "mask") }
            let (mask, resampled) = try Raster.loadMask(url, width: image.width, height: image.height)
            if resampled {
                warnings.append(Warning(code: ImageProfile.WarningCode.maskResampled, message: "The mask was resized to the image.",
                                        param: "mask"))
            }
            return mask
        }
        let prompt = context.input("prompt")?.text ?? context.input("instruction")?.text ?? ""
        var effective: [String: JSONValue] = ["model_params": ["mock": true]]
        if !context.extensions.isEmpty { effective["extensions"] = .object(context.extensions) }
        var outputs: [ProducedOutput] = []

        switch context.operation {
        case "image.generate":
            let (w, h, snapped) = Self.outputSize(context.params)
            if snapped {
                warnings.append(Warning(code: ImageProfile.WarningCode.sizeSnapped, message: "Snapped to the mock's 16-px grid: \(w)×\(h).",
                                        param: "size"))
            }
            effective["size"] = ["width": .number(Double(w)), "height": .number(Double(h))]
            let count = context.param("count")?.intValue ?? 1
            for i in 0..<count {
                let a = Palette.color(prompt, seed: seed + i), b = Palette.color(prompt + "~", seed: seed + i)
                var r = Raster(width: w, height: h)
                for y in 0..<h {
                    let t = Double(y) / Double(max(1, h - 1))
                    for x in 0..<w { r[x, y] = (Palette.blend(a.0, b.0, t), Palette.blend(a.1, b.1, t), Palette.blend(a.2, b.2, t), 255) }
                }
                outputs.append(try png(r, "images", i))
            }

        case "image.edit":
            var r = try loadImage("images")
            let strength = context.param("strength")?.numberValue ?? 0.75
            let c = Palette.color(prompt, seed: seed)
            Self.tint(&r, c, amount: 0.4 * strength)
            outputs.append(try png(r, "image"))

        case "image.fill", "image.erase":
            let input = try loadImage("image")
            let mask = try loadMask(for: input)
            let strength = context.param("strength")?.numberValue ?? 1
            let target = context.operation == "image.fill" ? Palette.color(prompt, seed: seed) : input.meanColor
            var r = input
            for y in 0..<r.height {
                for x in 0..<r.width {
                    let m = mask[y * r.width + x]
                    guard m > 0 else { continue }                      // Image §1.7: black stays byte-identical
                    let t = Double(m) / 255 * (context.operation == "image.fill" ? max(strength, 0.01) : 1)
                    let p = input[x, y]
                    r[x, y] = (Palette.blend(p.0, target.0, t), Palette.blend(p.1, target.1, t), Palette.blend(p.2, target.2, t), p.3)
                }
            }
            outputs.append(try png(r, "image"))

        case "image.extend":
            let input = try loadImage("image")
            let (left, top, right, bottom) = try Self.canvasInsets(context.params[ImageProfile.Param.canvas], width: input.width, height: input.height)
            let fillColor = input.meanColor
            var r = Raster(width: input.width + left + right, height: input.height + top + bottom,
                           fill: (fillColor.0, fillColor.1, fillColor.2, 255))
            for y in 0..<input.height { for x in 0..<input.width { r[x + left, y + top] = input[x, y] } }
            outputs.append(try png(r, "image"))

        case "image.upscale":
            let input = try loadImage("image")
            let scale = context.param("scale")?.intValue ?? 2
            let r = try Raster.draw(input.cgImage(), width: input.width * scale, height: input.height * scale)
            effective["scale"] = .number(Double(scale))
            outputs.append(try png(r, "image"))

        case "image.restore":
            outputs.append(try png(try loadImage("image"), "image"))

        case "image.relight":
            var r = try loadImage("image")
            let k = 1 + 0.3 * (context.param("strength")?.numberValue ?? 0.75)
            for i in stride(from: 0, to: r.pixels.count, by: 4) {
                for c in 0..<3 { r.pixels[i + c] = UInt8(min(255, Double(r.pixels[i + c]) * k)) }
            }
            outputs.append(try png(r, "image"))

        case "image.colorize":
            var r = try loadImage("image")
            for y in 0..<r.height {
                for x in 0..<r.width {
                    let l = Double(r.luminance(x, y)), a = r[x, y].3
                    r[x, y] = (UInt8(min(255, l * 1.07)), UInt8(min(255, l * 0.74 + 40)), UInt8(min(255, l * 0.43 + 20)), a)
                }
            }
            outputs.append(try png(r, "image"))

        case "image.matte":
            let input = try loadImage("image")
            let mask = Self.subjectMask(input)
            let wanted = context.param("outputs")?.arrayValue?.compactMap(\.stringValue) ?? ["mask", "extract"]
            if wanted.contains("mask") {
                let url = out.appendingPathComponent("mask.png")
                try Raster.writeGreyPNG(mask, width: input.width, height: input.height, to: url)
                outputs.append(.file(url, name: "mask", kind: .mask, mediaType: "image/png", width: input.width, height: input.height))
            }
            if wanted.contains("extract") {
                var r = input
                for y in 0..<r.height {
                    for x in 0..<r.width {
                        let a = mask[y * r.width + x], p = input[x, y], t = Double(a) / 255
                        r[x, y] = (UInt8(Double(p.0) * t), UInt8(Double(p.1) * t), UInt8(Double(p.2) * t), a)  // premultiplied
                    }
                }
                outputs.append(try png(r, "extract"))
            }

        case "image.segment":
            let input = try loadImage("image")
            let points = context.input("points")?.data?.arrayValue ?? []
            let count = context.param("count")?.intValue ?? 1
            for i in 0..<count {
                let mask = Self.segmentMask(width: input.width, height: input.height, points: points, grow: Double(i) * 0.05)
                let url = out.appendingPathComponent("mask-\(i).png")
                try Raster.writeGreyPNG(mask, width: input.width, height: input.height, to: url)
                outputs.append(.file(url, name: "masks", kind: .mask, mediaType: "image/png", width: input.width, height: input.height))
            }

        case "image.describe":
            let input = try loadImage("image")
            let orientation = input.width >= input.height ? (input.width == input.height ? "square" : "landscape") : "portrait"
            let language = context.param("language")?.stringValue ?? "en"
            outputs.append(.data(["caption": .string("A \(input.width)×\(input.height) \(orientation) image (mock description)."),
                                  "alt_text": .string("Mock description of a \(orientation) image"),
                                  "tags": ["mock", .string(orientation)], "language": .string(language)], name: "description"))

        case "image.score":
            let input = try loadImage("image")
            var total = 0
            for y in 0..<input.height { for x in 0..<input.width { total += input.luminance(x, y) } }
            let mean = Double(total) / Double(max(1, input.width * input.height)) / 255
            outputs.append(.data(["score": .number((mean * 1000).rounded() / 1000), "scale": "mock-mean-luminance"], name: "score"))

        default:
            throw MESError(.unknownOperation, "The mock doesn't implement \(context.operation).")
        }
        return RunOutput(outputs: outputs, effective: effective,
                         seed: ["image.generate", "image.edit", "image.fill", "image.relight", "image.colorize", "image.extend"]
                             .contains(context.operation) ? seed : nil,
                         warnings: warnings)
    }

    // MARK: - Helpers

    /// `size`, or `aspect` + `megapixels`, snapped to a 16-px grid like many models'.
    static func outputSize(_ params: [String: JSONValue]) -> (Int, Int, snapped: Bool) {
        var w = 1024, h = 1024
        if let size = params["size"], let sw = size["width"]?.intValue, let sh = size["height"]?.intValue {
            w = sw; h = sh
        } else if let aspect = params["aspect"]?.stringValue {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            let mp = params["megapixels"]?.numberValue ?? 1
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                let ratio = parts[0] / parts[1]
                let area = mp * 1_000_000
                w = Int((area * ratio).squareRoot()); h = Int((area / ratio).squareRoot())
            }
        }
        let sw = max(16, (w + 8) / 16 * 16), sh = max(16, (h + 8) / 16 * 16)
        return (sw, sh, sw != w || sh != h)
    }

    static func canvasInsets(_ canvas: JSONValue?, width: Int, height: Int) throws -> (Int, Int, Int, Int) {
        guard let canvas else { return (width / 4, 0, width / 4, 0) }
        if let l = canvas["left"]?.intValue, let t = canvas["top"]?.intValue, let r = canvas["right"]?.intValue,
           let b = canvas["bottom"]?.intValue {
            return (l, t, r, b)
        }
        guard let size = canvas["size"], let tw = size["width"]?.intValue, let th = size["height"]?.intValue,
              tw >= width, th >= height else {
            throw MESError(.outOfLimits, "canvas.size must be at least the image's size.", param: "canvas")
        }
        let dx = tw - width, dy = th - height
        switch canvas["anchor"]?.stringValue ?? "center" {
        case "top_left": return (0, 0, dx, dy)
        case "top": return (dx / 2, 0, dx - dx / 2, dy)
        case "top_right": return (dx, 0, 0, dy)
        case "left": return (0, dy / 2, dx, dy - dy / 2)
        case "right": return (dx, dy / 2, 0, dy - dy / 2)
        case "bottom_left": return (0, dy, dx, 0)
        case "bottom": return (dx / 2, dy, dx - dx / 2, 0)
        case "bottom_right": return (dx, dy, 0, 0)
        default: return (dx / 2, dy / 2, dx - dx / 2, dy - dy / 2)
        }
    }

    static func tint(_ r: inout Raster, _ c: (UInt8, UInt8, UInt8), amount: Double) {
        for i in stride(from: 0, to: r.pixels.count, by: 4) {
            r.pixels[i] = Palette.blend(r.pixels[i], c.0, amount)
            r.pixels[i + 1] = Palette.blend(r.pixels[i + 1], c.1, amount)
            r.pixels[i + 2] = Palette.blend(r.pixels[i + 2], c.2, amount)
        }
    }

    /// Pixels far from the border's mean colour are "subject".
    static func subjectMask(_ r: Raster) -> [UInt8] {
        var br = 0, bg = 0, bb = 0, n = 0
        for x in 0..<r.width { for y in [0, r.height - 1] { let p = r[x, y]; br += Int(p.0); bg += Int(p.1); bb += Int(p.2); n += 1 } }
        let mr = br / max(1, n), mg = bg / max(1, n), mb = bb / max(1, n)
        var mask = [UInt8](repeating: 0, count: r.width * r.height)
        for y in 0..<r.height {
            for x in 0..<r.width {
                let p = r[x, y]
                let d = abs(Int(p.0) - mr) + abs(Int(p.1) - mg) + abs(Int(p.2) - mb)
                mask[y * r.width + x] = d > 60 ? 255 : 0
            }
        }
        return mask
    }

    static func segmentMask(width: Int, height: Int, points: [JSONValue], grow: Double) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        let includes = points.filter { $0["label"]?.stringValue != "exclude" }
        let centers: [(Double, Double)] = includes.isEmpty ? [(0.5, 0.5)]
            : includes.compactMap { p in p["x"]?.numberValue.flatMap { x in p["y"]?.numberValue.map { (x, $0) } } }
        let radius = (0.15 + grow) * Double(min(width, height))
        for y in 0..<height {
            for x in 0..<width {
                for (cx, cy) in centers {
                    let dx = Double(x) - cx * Double(width), dy = Double(y) - cy * Double(height)
                    if dx * dx + dy * dy <= radius * radius { mask[y * width + x] = 255; break }
                }
            }
        }
        return mask
    }
}
