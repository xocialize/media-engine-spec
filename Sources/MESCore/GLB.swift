import Foundation

/// A glTF 2.0 binary file (GLB) as the Mesh profile carries it (Mesh §1.1, §1.2): the glTF JSON and the one BIN chunk.
/// Reads accessors, walks the scene with its node transforms, computes the facts a mesh output reports (Base §10.1, RFC
/// 0007), lists what breaks the profile's conventions, and builds files: enough for engines, the conformance suite and
/// viewers, with no dependency beyond Foundation. It reads no extensions (Draco, meshopt).
public struct GLB: Sendable, Equatable {
    public var json: [String: JSONValue]
    public var bin: Data

    public init(json: [String: JSONValue] = ["asset": ["version": "2.0"]], bin: Data = Data()) {
        self.json = json
        self.bin = bin
    }

    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    // glTF constants.
    public static let float = 5126, unsignedByte = 5121, unsignedShort = 5123, unsignedInt = 5125, byte = 5120, short = 5122
    public static let arrayBuffer = 34962, elementArrayBuffer = 34963
    static let magic: UInt32 = 0x4654_6C67, jsonChunk: UInt32 = 0x4E4F_534A, binChunk: UInt32 = 0x004E_4942

    // MARK: - Reading and writing the container

    /// Parses a GLB. Throws when the bytes aren't a glTF 2.0 binary file.
    public init(data: Data) throws {
        let d = Data(data)
        guard d.count >= 20 else { throw Failure("too short to be a GLB (\(d.count) bytes)") }
        guard d.u32(0) == Self.magic else { throw Failure("not a GLB: no glTF magic") }
        guard d.u32(4) == 2 else { throw Failure("glTF binary version \(d.u32(4)), not 2") }
        let total = Int(d.u32(8))
        guard total <= d.count else { throw Failure("the header says \(total) bytes; the file has \(d.count)") }
        var offset = 12
        var chunks: [(UInt32, Data)] = []
        while offset + 8 <= total {
            let length = Int(d.u32(offset)), type = d.u32(offset + 4)
            guard offset + 8 + length <= total else { throw Failure("chunk at \(offset) runs past the end") }
            chunks.append((type, d.subdata(in: (offset + 8)..<(offset + 8 + length))))
            offset += 8 + length
        }
        guard let first = chunks.first, first.0 == Self.jsonChunk else { throw Failure("the first chunk isn't JSON") }
        guard case .object(let object) = try MESJSON.decoder.decode(JSONValue.self, from: first.1) else {
            throw Failure("the JSON chunk isn't an object")
        }
        json = object
        bin = chunks.dropFirst().first { $0.0 == Self.binChunk }?.1 ?? Data()
        chunkTypes = chunks.map(\.0)
    }

    /// The chunk types the file had, in order (for `problems()`); empty for a GLB built in memory.
    public private(set) var chunkTypes: [UInt32] = []

    /// The file: header, the JSON chunk (padded with spaces) and the BIN chunk (padded with zeros), with
    /// `buffers[0].byteLength` set to the BIN chunk's length.
    public func data() throws -> Data {
        var object = json
        var paddedBin = bin
        while paddedBin.count % 4 != 0 { paddedBin.append(0) }
        if !bin.isEmpty {
            var buffers = object["buffers"]?.arrayValue ?? [[:]]
            if buffers.isEmpty { buffers = [[:]] }
            var first = buffers[0].objectValue ?? [:]
            first["byteLength"] = .number(Double(paddedBin.count))
            first["uri"] = nil
            buffers[0] = .object(first)
            object["buffers"] = .array(buffers)
        }
        var text = try MESJSON.encoder.encode(JSONValue.object(object))
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data()
        out.appendU32(Self.magic)
        out.appendU32(2)
        out.appendU32(UInt32(12 + 8 + text.count + (paddedBin.isEmpty ? 0 : 8 + paddedBin.count)))
        out.appendU32(UInt32(text.count))
        out.appendU32(Self.jsonChunk)
        out.append(text)
        if !paddedBin.isEmpty {
            out.appendU32(UInt32(paddedBin.count))
            out.appendU32(Self.binChunk)
            out.append(paddedBin)
        }
        return out
    }

    // MARK: - JSON helpers

    public func array(_ key: String) -> [JSONValue] { json[key]?.arrayValue ?? [] }
    public func object(_ key: String, _ index: Int) -> [String: JSONValue]? {
        let a = array(key)
        return a.indices.contains(index) ? a[index].objectValue : nil
    }
    /// Appends to a top-level array, returning the new item's index.
    @discardableResult
    public mutating func append(_ key: String, _ value: JSONValue) -> Int {
        var a = array(key)
        a.append(value)
        json[key] = .array(a)
        return a.count - 1
    }
    public mutating func set(_ key: String, _ index: Int, _ value: [String: JSONValue]) {
        var a = array(key)
        a[index] = .object(value)
        json[key] = .array(a)
    }

    /// The `asset` object.
    public var asset: [String: JSONValue] {
        get { json["asset"]?.objectValue ?? [:] }
        set { json["asset"] = .object(newValue) }
    }
    /// `asset.extras.mes`, where the profile's disclosure and licences go (Mesh §1.11, §1.12).
    public var mesExtras: [String: JSONValue] {
        get { asset["extras"]?["mes"]?.objectValue ?? [:] }
        set {
            var a = asset
            var extras = a["extras"]?.objectValue ?? [:]
            extras["mes"] = .object(newValue)
            a["extras"] = .object(extras)
            asset = a
        }
    }

    // MARK: - Building

    /// Appends bytes to the BIN chunk (4-byte aligned) as a new buffer view, returning its index.
    @discardableResult
    public mutating func addBufferView(_ bytes: Data, target: Int? = nil) -> Int {
        while bin.count % 4 != 0 { bin.append(0) }
        var view: [String: JSONValue] = ["buffer": 0, "byteOffset": .number(Double(bin.count)), "byteLength": .number(Double(bytes.count))]
        if let target { view["target"] = .number(Double(target)) }
        bin.append(bytes)
        if array("buffers").isEmpty { json["buffers"] = [["byteLength": 0]] }
        return append("bufferViews", .object(view))
    }

    @discardableResult
    public mutating func addAccessor(bufferView: Int, componentType: Int, count: Int, type: String, normalized: Bool = false,
                                     min: [Double]? = nil, max: [Double]? = nil) -> Int {
        var a: [String: JSONValue] = ["bufferView": .number(Double(bufferView)), "componentType": .number(Double(componentType)),
                                      "count": .number(Double(count)), "type": .string(type)]
        if normalized { a["normalized"] = true }
        if let min { a["min"] = .array(min.map { .number(Double(Float($0))) }) }
        if let max { a["max"] = .array(max.map { .number(Double(Float($0))) }) }
        return append("accessors", .object(a))
    }

    /// Adds float vectors (`VEC2`, `VEC3`, `VEC4` or `MAT4`) as a buffer view and accessor, with `min`/`max` when asked.
    @discardableResult
    public mutating func addFloats(_ vectors: [[Float]], type: String, bounds: Bool = false, target: Int? = arrayBuffer) -> Int {
        var bytes = Data(capacity: vectors.count * (vectors.first?.count ?? 0) * 4)
        for v in vectors { for x in v { bytes.appendF32(x) } }
        let view = addBufferView(bytes, target: target)
        var lo: [Double]?, hi: [Double]?
        if bounds, let n = vectors.first?.count {
            lo = (0..<n).map { i in Double(vectors.map { $0[i] }.min() ?? 0) }
            hi = (0..<n).map { i in Double(vectors.map { $0[i] }.max() ?? 0) }
        }
        return addAccessor(bufferView: view, componentType: Self.float, count: vectors.count, type: type, min: lo, max: hi)
    }

    /// Adds unsigned integers: indices (`SCALAR`, 16- or 32-bit as they need) or joint indices (`VEC4`, 16-bit).
    @discardableResult
    public mutating func addIndices(_ values: [UInt32]) -> Int {
        let wide = (values.max() ?? 0) > UInt32(UInt16.max)
        var bytes = Data(capacity: values.count * (wide ? 4 : 2))
        for v in values { if wide { bytes.appendU32(v) } else { bytes.appendU16(UInt16(v)) } }
        let view = addBufferView(bytes, target: Self.elementArrayBuffer)
        return addAccessor(bufferView: view, componentType: wide ? Self.unsignedInt : Self.unsignedShort, count: values.count, type: "SCALAR")
    }

    @discardableResult
    public mutating func addJoints(_ joints: [[UInt16]]) -> Int {
        var bytes = Data(capacity: joints.count * 8)
        for j in joints { for k in 0..<4 { bytes.appendU16(k < j.count ? j[k] : 0) } }
        let view = addBufferView(bytes, target: Self.arrayBuffer)
        return addAccessor(bufferView: view, componentType: Self.unsignedShort, count: joints.count, type: "VEC4")
    }

    /// Adds an image (PNG or JPEG bytes) embedded through a buffer view, returning the image's index.
    @discardableResult
    public mutating func addImage(_ bytes: Data, mediaType: String) -> Int {
        let view = addBufferView(bytes)
        return append("images", ["bufferView": .number(Double(view)), "mimeType": .string(mediaType)])
    }

    /// A one-node, one-primitive GLB from vertex data (Mesh §1.2, §1.5): `colors` for a vertex-coloured mesh, `uvs` and
    /// `texture` (PNG) for a textured one, `metallic`/`roughness` factors for its PBR material.
    public static func mesh(positions: [[Float]], normals: [[Float]], indices: [UInt32], uvs: [[Float]]? = nil,
                            colors: [[Float]]? = nil, texture: Data? = nil, textureMediaType: String = "image/png",
                            metallic: Double = 0, roughness: Double = 0.8, generator: String = "MESKit") -> GLB {
        var g = GLB(json: ["asset": ["version": "2.0", "generator": .string(generator)], "scene": 0])
        var attributes: [String: JSONValue] = [
            "POSITION": .number(Double(g.addFloats(positions, type: "VEC3", bounds: true))),
            "NORMAL": .number(Double(g.addFloats(normals, type: "VEC3"))),
        ]
        var pbr: [String: JSONValue] = ["metallicFactor": .number(metallic), "roughnessFactor": .number(roughness)]
        if let uvs, let texture {
            attributes["TEXCOORD_0"] = .number(Double(g.addFloats(uvs, type: "VEC2")))
            let image = g.addImage(texture, mediaType: textureMediaType)
            g.append("samplers", ["magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071])
            let tex = g.append("textures", ["source": .number(Double(image)), "sampler": 0])
            pbr["baseColorTexture"] = ["index": .number(Double(tex))]
        } else if let colors {
            attributes["COLOR_0"] = .number(Double(g.addFloats(colors, type: colors.first?.count == 3 ? "VEC3" : "VEC4")))
        }
        let idx = g.addIndices(indices)
        g.append("materials", ["pbrMetallicRoughness": .object(pbr), "doubleSided": false])
        g.append("meshes", ["primitives": [["attributes": .object(attributes), "indices": .number(Double(idx)), "material": 0, "mode": 4]]])
        g.append("nodes", ["mesh": 0, "name": "object"])
        g.append("scenes", ["nodes": [0]])
        return g
    }

    // MARK: - Accessors

    static func components(_ type: String) -> Int {
        ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16][type] ?? 0
    }
    static func size(_ componentType: Int) -> Int {
        switch componentType { case byte, unsignedByte: 1; case short, unsignedShort: 2; default: 4 }
    }

    /// An accessor's elements as floats (`FLOAT`, or normalized or plain integers), honouring `byteStride`.
    public func floats(accessor index: Int) throws -> [[Float]] {
        let (raw, n, ct, normalized) = try elements(index)
        return raw.map { comps in
            comps.map { v in
                guard ct != Self.float else { return Float(bitPattern: UInt32(truncatingIfNeeded: v)) }
                guard normalized else { return Float(v) }
                switch ct {
                case Self.unsignedByte: return Float(v) / 255
                case Self.unsignedShort: return Float(v) / 65535
                case Self.byte: return Swift.max(Float(Int8(truncatingIfNeeded: v)) / 127, -1)
                case Self.short: return Swift.max(Float(Int16(truncatingIfNeeded: v)) / 32767, -1)
                default: return Float(v)
                }
            }
        }.map { Array($0.prefix(n)) }
    }

    /// An accessor's elements as unsigned integers (indices, joints).
    public func ints(accessor index: Int) throws -> [[UInt32]] {
        let (raw, _, ct, _) = try elements(index)
        guard ct != Self.float else { throw Failure("accessor \(index) is float, not integers") }
        return raw.map { $0.map { UInt32(truncatingIfNeeded: $0) } }
    }

    /// Raw element bit patterns, each component zero-extended to 64 bits.
    func elements(_ index: Int) throws -> ([[UInt64]], Int, Int, Bool) {
        guard let a = object("accessors", index) else { throw Failure("no accessor \(index)") }
        guard a["sparse"] == nil else { throw Failure("accessor \(index) is sparse, which this reader doesn't read") }
        let count = a["count"]?.intValue ?? 0, ct = a["componentType"]?.intValue ?? 0
        let n = Self.components(a["type"]?.stringValue ?? ""), size = Self.size(ct)
        guard n > 0 else { throw Failure("accessor \(index) has an unknown type") }
        guard let viewIndex = a["bufferView"]?.intValue else { return (Array(repeating: Array(repeating: 0, count: n), count: count), n, ct, a["normalized"]?.boolValue ?? false) }
        guard let view = object("bufferViews", viewIndex) else { throw Failure("accessor \(index): no buffer view \(viewIndex)") }
        guard (view["buffer"]?.intValue ?? 0) == 0, array("buffers").first?["uri"] == nil else {
            throw Failure("accessor \(index) reads a buffer outside the file")
        }
        let base = (view["byteOffset"]?.intValue ?? 0) + (a["byteOffset"]?.intValue ?? 0)
        let stride = view["byteStride"]?.intValue ?? n * size
        let end = base + (count > 0 ? (count - 1) * stride + n * size : 0)
        guard end <= bin.count else { throw Failure("accessor \(index) runs past the BIN chunk") }
        var out: [[UInt64]] = []
        out.reserveCapacity(count)
        bin.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in 0..<count {
                var comps = [UInt64](repeating: 0, count: n)
                for c in 0..<n {
                    let at = base + i * stride + c * size
                    switch size {
                    case 1: comps[c] = UInt64(p[at])
                    case 2: comps[c] = UInt64(p.loadUnaligned(fromByteOffset: at, as: UInt16.self).littleEndian)
                    default: comps[c] = UInt64(p.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian)
                    }
                }
                out.append(comps)
            }
        }
        return (out, n, ct, a["normalized"]?.boolValue ?? false)
    }

    /// A buffer view's bytes (an embedded image).
    public func bufferView(_ index: Int) throws -> Data {
        guard let view = object("bufferViews", index) else { throw Failure("no buffer view \(index)") }
        let start = view["byteOffset"]?.intValue ?? 0, length = view["byteLength"]?.intValue ?? 0
        guard start + length <= bin.count else { throw Failure("buffer view \(index) runs past the BIN chunk") }
        return bin.subdata(in: start..<(start + length))
    }

    /// An image's bytes and media type.
    public func image(_ index: Int) throws -> (Data, String) {
        guard let image = object("images", index) else { throw Failure("no image \(index)") }
        guard let view = image["bufferView"]?.intValue else { throw Failure("image \(index) isn't embedded") }
        return (try bufferView(view), image["mimeType"]?.stringValue ?? "image/png")
    }

    // MARK: - The scene

    /// One primitive as placed in the scene: its node, mesh and index, attributes, and the node's world matrix.
    public struct Primitive: Sendable {
        public var node: Int
        public var mesh: Int
        public var index: Int
        public var attributes: [String: Int]
        public var indices: Int?
        public var mode: Int
        public var material: Int?
        /// Column-major 4×4.
        public var world: [Double]
        public var skin: Int?
    }

    /// Every primitive the default scene draws (a node with a mesh counts each time it appears).
    public func primitives() -> [Primitive] {
        var out: [Primitive] = []
        let sceneIndex = json["scene"]?.intValue ?? 0
        let roots = object("scenes", sceneIndex)?["nodes"]?.arrayValue?.compactMap(\.intValue)
            ?? Array(0..<array("nodes").count).filter { n in !array("nodes").contains { $0["children"]?.arrayValue?.contains(.number(Double(n))) == true } }
        func visit(_ n: Int, _ parent: [Double], depth: Int) {
            guard depth < 64, let node = object("nodes", n) else { return }
            let world = Matrix.multiply(parent, Matrix.local(node))
            if let m = node["mesh"]?.intValue, let mesh = object("meshes", m) {
                for (i, p) in (mesh["primitives"]?.arrayValue ?? []).enumerated() {
                    let attrs = (p["attributes"]?.objectValue ?? [:]).compactMapValues(\.intValue)
                    out.append(Primitive(node: n, mesh: m, index: i, attributes: attrs, indices: p["indices"]?.intValue,
                                         mode: p["mode"]?.intValue ?? 4, material: p["material"]?.intValue, world: world,
                                         skin: node["skin"]?.intValue))
                }
            }
            for c in node["children"]?.arrayValue?.compactMap(\.intValue) ?? [] { visit(c, world, depth: depth + 1) }
        }
        for r in roots { visit(r, Matrix.identity, depth: 0) }
        return out
    }

    /// A primitive's positions in scene space.
    public func worldPositions(_ p: Primitive) throws -> [[Double]] {
        guard let pos = p.attributes["POSITION"] else { throw Failure("mesh \(p.mesh) primitive \(p.index) has no POSITION") }
        return try floats(accessor: pos).map { Matrix.apply(p.world, $0.map(Double.init)) }
    }

    /// A primitive's triangles as vertex indices.
    public func triangles(_ p: Primitive) throws -> [UInt32] {
        if let i = p.indices { return try ints(accessor: i).map { $0[0] } }
        let n = (object("accessors", p.attributes["POSITION"] ?? -1)?["count"]?.intValue ?? 0)
        return (0..<UInt32(n)).map { $0 }
    }

    // MARK: - Facts and conventions

    /// What a mesh output reports (Base §10.1, RFC 0007), read from the file.
    public struct Facts: Sendable, Equatable {
        public var vertices: Int
        public var faces: Int
        public var bounds: MeshBounds
        /// The largest embedded image's longest side; nil when the mesh has no texture.
        public var textureSize: Int?
        /// The skins' joints; nil when unskinned.
        public var joints: Int?
        public var hasVertexColors: Bool
        public var hasNormals: Bool
    }

    public func facts() throws -> Facts {
        var vertices = 0, faces = 0
        var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
        var colors = false, normals = true
        for p in primitives() {
            let positions = try worldPositions(p)
            vertices += positions.count
            faces += (p.indices.flatMap { object("accessors", $0)?["count"]?.intValue } ?? positions.count) / 3
            for v in positions { for k in 0..<3 { lo[k] = Swift.min(lo[k], v[k]); hi[k] = Swift.max(hi[k], v[k]) } }
            colors = colors || p.attributes["COLOR_0"] != nil
            normals = normals && p.attributes["NORMAL"] != nil
        }
        if vertices == 0 { lo = [0, 0, 0]; hi = [0, 0, 0] }
        var texture: Int?
        for i in array("images").indices {
            if let (data, _) = try? image(i), let size = ImageSize.of(data) { texture = Swift.max(texture ?? 0, Swift.max(size.width, size.height)) }
        }
        let jointSet = Set(array("skins").flatMap { $0["joints"]?.arrayValue?.compactMap(\.intValue) ?? [] })
        return Facts(vertices: vertices, faces: faces, bounds: MeshBounds(min: lo, max: hi), textureSize: texture,
                     joints: jointSet.isEmpty ? nil : jointSet.count, hasVertexColors: colors, hasNormals: normals)
    }

    /// What breaks Mesh §1.1 and §1.2 (empty when the file follows them): one JSON and one BIN chunk, nothing outside
    /// the file, no required extensions, triangles with float positions carrying `min` and `max`, normals, and 16- or
    /// 32-bit indices.
    public func problems() -> [String] {
        var out: [String] = []
        if !chunkTypes.isEmpty, chunkTypes != [Self.jsonChunk, Self.binChunk] {
            out.append("chunks aren't one JSON and one BIN (\(chunkTypes.count) chunks)")
        }
        if asset["version"]?.stringValue != "2.0" { out.append("asset.version isn't 2.0") }
        if let required = json["extensionsRequired"]?.arrayValue, !required.isEmpty {
            out.append("requires extensions: \(required.compactMap(\.stringValue).joined(separator: ", "))")
        }
        if array("buffers").count > 1 || array("buffers").contains(where: { $0["uri"] != nil }) { out.append("a buffer outside the file") }
        if array("images").contains(where: { $0["uri"] != nil }) { out.append("an image outside the file") }
        let prims = primitives()
        if prims.isEmpty { out.append("the scene draws no mesh") }
        for p in prims {
            let what = "mesh \(p.mesh) primitive \(p.index)"
            if p.mode != 4 { out.append("\(what) isn't triangles (mode \(p.mode))") }
            if let pos = p.attributes["POSITION"], let a = object("accessors", pos) {
                if a["componentType"]?.intValue != Self.float || a["type"]?.stringValue != "VEC3" { out.append("\(what): POSITION isn't float VEC3") }
                if a["min"] == nil || a["max"] == nil { out.append("\(what): POSITION has no min and max") }
            } else {
                out.append("\(what) has no POSITION")
            }
            if p.attributes["NORMAL"] == nil { out.append("\(what) has no NORMAL") }
            if let i = p.indices, let ct = object("accessors", i)?["componentType"]?.intValue, ![Self.unsignedShort, Self.unsignedInt].contains(ct) {
                out.append("\(what): indices aren't 16- or 32-bit")
            }
        }
        return out
    }
}

// MARK: - Matrices (column-major 4×4, glTF's)

enum Matrix {
    static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 16)
        for col in 0..<4 { for row in 0..<4 { for k in 0..<4 { r[col * 4 + row] += a[k * 4 + row] * b[col * 4 + k] } } }
        return r
    }

    static func apply(_ m: [Double], _ v: [Double]) -> [Double] {
        (0..<3).map { row in m[row] * v[0] + m[4 + row] * v[1] + m[8 + row] * v[2] + m[12 + row] }
    }

    /// A node's local matrix: `matrix`, or translation × rotation × scale.
    static func local(_ node: [String: JSONValue]) -> [Double] {
        if let m = node["matrix"]?.arrayValue?.compactMap(\.numberValue), m.count == 16 { return m }
        let t = node["translation"]?.arrayValue?.compactMap(\.numberValue) ?? [0, 0, 0]
        let q = node["rotation"]?.arrayValue?.compactMap(\.numberValue) ?? [0, 0, 0, 1]
        let s = node["scale"]?.arrayValue?.compactMap(\.numberValue) ?? [1, 1, 1]
        guard t.count == 3, q.count == 4, s.count == 3 else { return identity }
        let (x, y, z, w) = (q[0], q[1], q[2], q[3])
        let r: [Double] = [1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0,
                           2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0,
                           2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0,
                           0, 0, 0, 1]
        var m = r
        for col in 0..<3 { for row in 0..<3 { m[col * 4 + row] *= s[col] } }
        m[12] = t[0]; m[13] = t[1]; m[14] = t[2]
        return m
    }
}

/// The pixel size of a PNG or JPEG from its header, without decoding it.
public enum ImageSize {
    public static func of(_ data: Data) -> (width: Int, height: Int)? {
        let d = Data(data)
        if d.count >= 24, d.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return (Int(d.u32be(16)), Int(d.u32be(20)))
        }
        guard d.count > 4, d[0] == 0xFF, d[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < d.count {
            guard d[i] == 0xFF else { i += 1; continue }
            let marker = d[i + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                return (Int(d[i + 7]) << 8 | Int(d[i + 8]), Int(d[i + 5]) << 8 | Int(d[i + 6]))
            }
            i += 2 + length
        }
        return nil
    }
}

extension Data {
    func u32(_ at: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian }
    }
    func u32be(_ at: Int) -> UInt32 {
        withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self).bigEndian }
    }
    mutating func appendU32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendU16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func appendF32(_ v: Float) { appendU32(v.bitPattern) }
}
