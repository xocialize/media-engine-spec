import AppKit
import Foundation
import MESCore
@testable import MESFormsUI
@testable import MockEngineCore
import SwiftUI
import Testing

// MESFormsUI for a part made to fit a body (RFC 0009): the `box` widget as a row of numbers and as a rectangle dragged on
// the picture, a form that follows the offers (a box and spring bones only where an offer takes them), what it says
// before sending, and a mesh well that takes a .vrm.

@Suite("MESFormsUI: a part made to fit a body", .serialized)
@MainActor
struct MeshPartFormsTests {
    func descriptor() async -> Descriptor {
        await MockMeshEngine().descriptors().first { $0.operation == "mesh.generate_part" }!
    }

    @Test("subject_box resolves to the box widget, from its hint or from its shape alone")
    func widget() async {
        let d = await descriptor()
        let fields = FormSchema.fields(of: d.params)
        let box = fields.first { $0.name == "subject_box" }
        #expect(box?.widget == .box && box?.label == "Where the part is" && box?.help?.contains("head") == true)
        #expect(fields.first { $0.name == "physics" }?.widget == .toggle)
        let shape: JSONValue = ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"],
                                                                 "width": ["type": "number"], "height": ["type": "number"]]]
        #expect(FormSchema.widget(name: "region", schema: shape, hint: nil) == .box)
        #expect(FormSchema.widget(name: "size", schema: ["type": "object", "properties": ["width": ["type": "integer"], "height": ["type": "integer"]]],
                                  hint: nil) == .size(minimum: 1))
    }

    @Test("A drag makes a box in shares of the picture: any direction, kept inside, and a click makes none")
    func dragging() {
        let size = CGSize(width: 400, height: 200)
        let box = ImageBoxPicker.box(from: CGPoint(x: 100, y: 20), to: CGPoint(x: 300, y: 100), in: size)
        #expect(box == SubjectBox(x: 0.25, y: 0.1, width: 0.5, height: 0.4))
        // Dragged up and to the left: the same box.
        #expect(ImageBoxPicker.box(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 100, y: 20), in: size) == box)
        // Past the edges: kept inside, and still a valid box.
        let clipped = ImageBoxPicker.box(from: CGPoint(x: -50, y: 150), to: CGPoint(x: 500, y: 400), in: size)
        #expect(clipped == SubjectBox(x: 0, y: 0.75, width: 1, height: 0.25) && clipped?.problem == nil)
        #expect(ImageBoxPicker.box(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 102, y: 101), in: size) == nil)
        #expect(ImageBoxPicker.box(from: .zero, to: CGPoint(x: 10, y: 10), in: .zero) == nil)
        #expect(ImageBoxPicker.rect(SubjectBox(x: 0.25, y: 0.1, width: 0.5, height: 0.4), in: size) == CGRect(x: 100, y: 20, width: 200, height: 80))
    }

    @Test("The form follows the offers: a box where one takes it, spring bones where one makes them, their parts and textures")
    func followsOffers() async {
        let form = OperationFormModel(descriptor: await descriptor())
        func shown() -> Set<String> { Set(form.fields.filter(form.shows).map(\.name)) }
        #expect(shown() == ["part", "subject_box", "physics", "texture", "seed", "quality"])
        // No model chosen: the engine may pick the finder, so nothing is needed yet.
        #expect(!form.needsSubjectBox && form.issues.isEmpty)

        form.model = "mock-part-finder"
        #expect(shown() == ["part", "texture", "seed", "quality"])
        let texture = form.narrowed(form.fields.first { $0.name == "texture" }!)
        #expect(texture.widget == .picker(["atlas"]))

        form.model = "mock-hairdeck"
        #expect(shown().contains("subject_box") && shown().contains("physics"))
        #expect(form.narrowed(form.fields.first { $0.name == "texture" }!).widget == .picker(["atlas", "none"]))
        #expect(form.narrowed(form.fields.first { $0.name == "part" }!).widget == .picker(["hair"]))
    }

    @Test("Said before sending: the chosen model needs a box, takes none, makes no springs; a box outside the picture")
    func issues() async {
        let form = OperationFormModel(descriptor: await descriptor())
        form.model = "mock-hairdeck"
        #expect(form.needsSubjectBox && form.issues["subject_box"]?.contains("Mock HairDeck needs a box") == true)
        form.setValue(["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4], at: ["subject_box"])
        #expect(form.issues.isEmpty)
        #expect(form.request().params?["subject_box"] == ["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4])
        form.setValue(["x": 0.8, "y": 0.1, "width": 0.5, "height": 0.4], at: ["subject_box"])
        #expect(form.issues["subject_box"]?.contains("inside the image") == true)

        form.setValue(["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4], at: ["subject_box"])
        form.setValue(true, at: ["physics"])
        form.setValue("none", at: ["texture"])
        form.model = "mock-part-finder"
        #expect(form.issues["subject_box"]?.contains("takes no box") == true)
        #expect(form.issues["physics"] == "Mock part finder makes no spring bones.")
        #expect(form.issues["texture"] == "Mock part finder doesn't make that surface.")
        // A field that holds a value stays on the form, so it can be seen and cleared.
        #expect(form.shows(form.fields.first { $0.name == "subject_box" }!) && form.shows(form.fields.first { $0.name == "physics" }!))
        form.reset()
        #expect(form.issues.isEmpty)
    }

    @Test("The box row, the picker on a picture, the part's form, and a .vrm in the mesh well render offscreen")
    func views() async throws {
        let d = await descriptor()
        let form = OperationFormModel(descriptor: d)
        form.model = "mock-hairdeck"
        form.showsAdvanced = true
        #expect(render(OperationForm(form: form)).height > 200)

        let field = form.fields.first { $0.name == "subject_box" }!
        var value: JSONValue? = ["x": 0.25, "y": 0.1, "width": 0.5, "height": 0.4]
        let binding = Binding(get: { value }, set: { value = $0 })
        #expect(render(FieldRow(field: field, value: binding, issue: nil)).height > 20)
        let editor = BoxEditor(field: field, value: binding)
        #expect(editor.percent("x").wrappedValue == 25 && editor.percent("height").wrappedValue == 40)
        editor.percent("width").wrappedValue = 60
        #expect(value?["width"] == 0.6 && value?["x"] == 0.25)
        value = nil
        editor.percent("x").wrappedValue = 10
        #expect(value == ["x": 0.1, "y": 0, "width": 1, "height": 1])

        let picture = FileManager.default.temporaryDirectory.appendingPathComponent("part-forms-\(UUID().uuidString).png")
        let body = FileManager.default.temporaryDirectory.appendingPathComponent("part-forms-\(UUID().uuidString).vrm")
        defer { for u in [picture, body] { try? FileManager.default.removeItem(at: u) } }
        try Raster(width: 40, height: 20, fill: (200, 60, 60, 255)).pngData().write(to: picture)
        let picker = try #require(ImageBoxPicker(file: picture, box: binding))
        #expect(picker.image.width == 40 && picker.image.height == 20)
        let drawn = render(picker, width: 300)
        #expect(abs(drawn.height - 150) < 2, "the picture keeps its shape: \(drawn)")
        #expect(ImageBoxPicker(file: body, box: binding) == nil)

        try MockMeshEngine.bodyGLB().write(to: body)
        #expect(MeshInputWell.extensions == ["glb", "vrm"])
        let spec = try #require(d.inputs.first { $0.name == "body" })
        #expect(render(MeshInputWell(spec: spec, file: .constant(body))).height > 300)
        #expect(try MeshFacts.read(body).joints == 52)
    }
}
