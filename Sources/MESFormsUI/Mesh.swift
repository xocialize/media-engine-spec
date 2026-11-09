import AppKit
import DesignScaffold
import MESCore
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

// Meshes in forms (Mesh 0.1): a viewer for mesh outputs with their facts and the preview still as its fallback, and a
// well for mesh inputs. macOS has no GLB loader (ModelIO, SceneKit and Quick Look don't read glTF), and RealityKit's
// materials can't show per-vertex colour, which TRELLIS.2 writes; so the viewer reads the file with MESCore's `GLB` and
// draws it in SceneKit.

// MARK: - Facts

/// What a mesh is, in one line: "118,204 vertices · 199,870 faces · 0.82 × 1.8 × 0.59 m · 2048 px texture · 22 joints".
public struct MeshFacts: Sendable, Equatable {
    public var vertices: Int
    public var faces: Int
    public var bounds: MeshBounds
    public var textureSize: Int?
    public var joints: Int?

    public init(vertices: Int, faces: Int, bounds: MeshBounds, textureSize: Int? = nil, joints: Int? = nil) {
        self.vertices = vertices; self.faces = faces; self.bounds = bounds; self.textureSize = textureSize; self.joints = joints
    }

    /// An output's reported facts (Base §10.1), when it has them.
    public init?(_ output: Output) {
        guard output.isMesh, let v = output.vertices, let f = output.faces, let b = output.bounds else { return nil }
        self.init(vertices: v, faces: f, bounds: b, textureSize: output.textureSize, joints: output.joints)
    }

    /// A file's facts.
    public static func read(_ file: URL) throws -> MeshFacts {
        let f = try GLB(data: Data(contentsOf: file)).facts()
        return MeshFacts(vertices: f.vertices, faces: f.faces, bounds: f.bounds, textureSize: f.textureSize, joints: f.joints)
    }

    public var line: String {
        let count = IntegerFormatStyle<Int>.number
        var parts = ["\(vertices.formatted(count)) vertices", "\(faces.formatted(count)) faces",
                     bounds.extents.map { $0.formatted(.number.precision(.significantDigits(1...3))) }.joined(separator: " × ") + " m"]
        if let textureSize { parts.append("\(textureSize) px texture") } else { parts.append("vertex colours") }
        if let joints { parts.append("\(joints) joints") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Viewer

/// A viewer for a mesh output (or any GLB): the model to orbit, with a line of facts and the required attribution of the
/// model that made it (Base §10.2 rule 1). When the file can't be shown (an extension this reader doesn't read, a broken
/// file), it shows `preview`, the still every mesh result comes with (Mesh §1.7).
public struct MeshView: View {
    let file: URL
    let preview: URL?
    let title: String?
    let reported: MeshFacts?
    let attribution: String?
    @State private var scene: SCNScene?
    @State private var facts: MeshFacts?
    @State private var failure: String?

    public init(file: URL, preview: URL? = nil, title: String? = nil, facts: MeshFacts? = nil, attribution: String? = nil) {
        self.file = file
        self.preview = preview
        self.title = title
        reported = facts
        self.attribution = attribution
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            if let title { Text(title).lineLimit(1) }
            ZStack {
                RoundedRectangle(cornerRadius: Tokens.Radius.control).fill(Tokens.Color.fieldFill)
                if let scene {
                    SceneSurface(scene: scene)
                } else if let preview, let image = NSImage(contentsOf: preview) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: "cube.transparent").font(.system(size: 36)).foregroundStyle(Tokens.Color.secondaryLabel)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .accessibilityLabel("3D model \(file.lastPathComponent)")
            if let line = (reported ?? facts)?.line {
                Text(line).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel)
            }
            if let failure {
                Text(failure).font(Tokens.Font.caption).foregroundStyle(scene == nil && preview == nil ? Tokens.Color.failure : Tokens.Color.secondaryLabel)
            }
            if let attribution { Text(attribution).font(Tokens.Font.caption) }
        }
        .task(id: file) {
            do {
                let glb = try GLB(data: Data(contentsOf: file))
                let f = try glb.facts()
                facts = MeshFacts(vertices: f.vertices, faces: f.faces, bounds: f.bounds, textureSize: f.textureSize, joints: f.joints)
                scene = try MeshScene.make(glb)
                failure = nil
            } catch {
                scene = nil
                failure = "Can't show \(file.lastPathComponent) in 3D (\(error))" + (preview == nil ? "." : "; showing its preview.")
            }
        }
    }
}

/// SceneKit's view, orbiting with the mouse.
struct SceneSurface: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.scene = scene
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== scene { view.scene = scene }
    }
}

/// A SceneKit scene from a GLB: each primitive in scene space (bind pose for a skinned mesh), with its normals, texture
/// or vertex colours, and a PBR material from its factors; a camera where the preview's is (Mesh §1.7).
public enum MeshScene {
    public static func make(_ glb: GLB) throws -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode()
        scene.rootNode.addChildNode(root)
        var textures: [Int: CGImage] = [:]
        for p in glb.primitives() where p.mode == 4 {
            let positions = try glb.worldPositions(p)
            var sources = [SCNGeometrySource(vertices: positions.map { SCNVector3($0[0], $0[1], $0[2]) })]
            if let n = p.attributes["NORMAL"] {
                let normals = try glb.floats(accessor: n).map { v -> SCNVector3 in
                    let w = p.world
                    let x = w[0] * Double(v[0]) + w[4] * Double(v[1]) + w[8] * Double(v[2])
                    let y = w[1] * Double(v[0]) + w[5] * Double(v[1]) + w[9] * Double(v[2])
                    let z = w[2] * Double(v[0]) + w[6] * Double(v[1]) + w[10] * Double(v[2])
                    let l = max((x * x + y * y + z * z).squareRoot(), 1e-9)
                    return SCNVector3(x / l, y / l, z / l)
                }
                sources.append(SCNGeometrySource(normals: normals))
            }
            if let t = p.attributes["TEXCOORD_0"] {
                sources.append(SCNGeometrySource(textureCoordinates: try glb.floats(accessor: t).map { CGPoint(x: Double($0[0]), y: Double($0[1])) }))
            }
            var vertexColors = false
            if let c = p.attributes["COLOR_0"] {
                let colors = try glb.floats(accessor: c)
                var bytes = Data(capacity: colors.count * 16)
                for v in colors { for k in 0..<4 { var f = k < v.count ? v[k] : 1; bytes.append(Data(bytes: &f, count: 4)) } }
                sources.append(SCNGeometrySource(data: bytes, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                                 componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0, dataStride: 16))
                vertexColors = true
            }
            let element = SCNGeometryElement(indices: try glb.triangles(p), primitiveType: .triangles)
            let geometry = SCNGeometry(sources: sources, elements: [element])
            geometry.materials = [material(glb, p, textures: &textures, vertexColors: vertexColors)]
            root.addChildNode(SCNNode(geometry: geometry))
        }
        let facts = try glb.facts()
        let center = facts.bounds.center, radius = max((facts.bounds.extents.map { $0 * $0 }.reduce(0, +)).squareRoot() / 2, 1e-3)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = radius * 0.01
        camera.camera?.zFar = radius * 100
        let az = 30.0 * .pi / 180, el = 20.0 * .pi / 180, distance = radius * 2.2
        camera.position = SCNVector3(center[0] + distance * sin(az) * cos(el), center[1] + distance * sin(el), center[2] + distance * cos(az) * cos(el))
        camera.look(at: SCNVector3(center[0], center[1], center[2]))
        scene.rootNode.addChildNode(camera)
        return scene
    }

    static func material(_ glb: GLB, _ p: GLB.Primitive, textures: inout [Int: CGImage], vertexColors: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.isDoubleSided = true
        let info = p.material.flatMap { glb.object("materials", $0) }
        let pbr = info?["pbrMetallicRoughness"]
        let factor = pbr?["baseColorFactor"]?.arrayValue?.compactMap(\.numberValue) ?? [1, 1, 1, 1]
        m.metalness.contents = pbr?["metallicFactor"]?.numberValue ?? 1
        m.roughness.contents = pbr?["roughnessFactor"]?.numberValue ?? 1
        if let tex = pbr?["baseColorTexture"]?["index"]?.intValue, let source = glb.object("textures", tex)?["source"]?.intValue {
            if textures[source] == nil, let (bytes, _) = try? glb.image(source), let src = CGImageSourceCreateWithData(bytes as CFData, nil) {
                textures[source] = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            if let image = textures[source] { m.diffuse.contents = image; return m }
        }
        let rgba = factor.count == 4 ? factor : [1, 1, 1, 1]
        m.diffuse.contents = vertexColors ? NSColor.white : NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
        return m
    }
}

// MARK: - Inputs

/// A media slot for a mesh input (`mesh.rig`): choose a GLB (or drop one), see it with its facts, clear it.
public struct MeshInputWell: View {
    let spec: InputSpec
    @Binding var file: URL?
    @State private var dropping = false

    public init(spec: InputSpec, file: Binding<URL?>) {
        self.spec = spec
        _file = file
    }

    static let glb = UTType(mimeType: MeshProfile.mediaType) ?? UTType(filenameExtension: "glb") ?? .data

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            HStack(spacing: Tokens.Space.s) {
                Image(systemName: "cube").foregroundStyle(Tokens.Color.secondaryLabel)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FormSchema.label(spec.name) + (spec.required ? "" : " (optional)"))
                    Text(file?.lastPathComponent ?? spec.notes ?? "A GLB file")
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.secondaryLabel).lineLimit(1)
                }
                Spacer()
                Button(file == nil ? "Choose…" : "Replace…", action: choose)
                if file != nil {
                    Button { file = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Clear \(FormSchema.label(spec.name))")
                }
            }
            if let file { MeshView(file: file) }
        }
        .padding(Tokens.Space.s)
        .background(dropping ? Tokens.Color.selectionWash : Tokens.Color.fieldFill, in: RoundedRectangle(cornerRadius: Tokens.Radius.control))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.control)
            .strokeBorder(Tokens.Color.separator, style: StrokeStyle(lineWidth: Tokens.Layout.hairline, dash: file == nil ? [4, 3] : [])))
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first(where: { $0.pathExtension.lowercased() == "glb" }) else { return false }
            file = first
            return true
        } isTargeted: { dropping = $0 }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.glb]
        panel.allowsMultipleSelection = false
        panel.message = "Choose \(FormSchema.label(spec.name).lowercased())"
        if panel.runModal() == .OK, let url = panel.url { file = url }
    }
}
