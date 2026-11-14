import AppKit
import DesignScaffold
import ImageIO
import MESCore
import SwiftUI

// A part made to fit a body in forms (Mesh §3.3, RFC 0009): the `box` widget (Base §6.1) for `subject_box`, as a rectangle
// dragged on the picture and as four numbers in the form; and a form that follows the offers, showing a box or spring
// bones only where an offer takes them and saying before sending what an engine would refuse.

// MARK: - The form follows the offers

extension OperationFormModel {
    typealias MP = MeshProfile.Param
    typealias MK = MeshProfile.SupportsKey

    static let generatePart = "mesh.generate_part"

    /// What an offer does with a `subject_box` (§3.3); nil when it locates the part itself.
    static func boxSupport(_ offer: ModelOffer) -> MeshProfile.SubjectBoxSupport? {
        offer.supports(MK.subjectBox)?.stringValue.flatMap(MeshProfile.SubjectBoxSupport.init(rawValue:))
    }

    /// Whether the request needs a box before it can run: every offer it may run on requires one.
    public var needsSubjectBox: Bool {
        descriptor.operation == Self.generatePart && !candidateOffers.isEmpty
            && candidateOffers.allSatisfy { Self.boxSupport($0) == .required }
    }

    /// Whether a part's field belongs on the form: the box only where an offer takes one, spring bones only where an
    /// offer makes them. A field that holds a value always shows.
    func meshShows(_ field: FormField) -> Bool {
        guard descriptor.operation == Self.generatePart, values[field.name] == nil else { return true }
        switch field.name {
        case MP.subjectBox: return candidateOffers.contains { Self.boxSupport($0) != nil }
        case MP.physics: return anyOffer(MK.physics)
        default: return true
        }
    }

    /// A part's field as the request's offers take it: the parts and textures they list.
    func meshNarrowed(_ field: FormField) -> FormField {
        guard descriptor.operation == Self.generatePart, case .picker(let options) = field.widget else { return field }
        var f = field
        switch field.name {
        case MP.part:
            let made = offered(MK.parts, absent: [])
            f.widget = .picker(options.filter { $0.stringValue.map(made.contains) ?? false })
        case MP.texture:
            let made = offered(MK.textures, absent: ["atlas"])
            f.widget = .picker(options.filter { $0.stringValue.map(made.contains) ?? false })
        default: break
        }
        return f
    }

    /// What an engine would refuse in a part's fields, said before sending (§3.3, §4.1), by parameter.
    var meshIssues: [String: String] {
        guard descriptor.operation == Self.generatePart else { return [:] }
        var out: [String: String] = [:]
        let chosen = model == nil ? nil : effectiveModel
        func list(_ m: ModelOffer, _ key: String, absent: [String] = []) -> [String] {
            m.supports(key)?.arrayValue?.compactMap(\.stringValue) ?? absent
        }
        if let box = values[MP.subjectBox] {
            if let problem = SubjectBox.problem(box) {
                out[MP.subjectBox] = problem
            } else if let m = chosen, Self.boxSupport(m) == nil {
                out[MP.subjectBox] = "\(m.title) finds the part itself and takes no box: clear it."
            }
        } else if needsSubjectBox {
            out[MP.subjectBox] = "\(chosen?.title ?? "This") needs a box: drag one on the picture, around where the part is."
        }
        if let m = chosen {
            if values[MP.physics]?.boolValue == true, m.supports(MK.physics)?.boolValue != true {
                out[MP.physics] = "\(m.title) makes no spring bones."
            }
            if let part = values[MP.part]?.stringValue, !list(m, MK.parts).contains(part) {
                out[MP.part] = "\(m.title) doesn't make \(FormSchema.display(.string(part)).lowercased())."
            }
            if let texture = values[MP.texture]?.stringValue, !list(m, MK.textures, absent: ["atlas"]).contains(texture) {
                out[MP.texture] = "\(m.title) doesn't make that surface."
            }
        }
        return out
    }
}

// MARK: - The box as four numbers

/// The `box` widget's row in a form: left, top, width and height as percentages of the picture. A host that shows the
/// picture puts `ImageBoxPicker` on it, bound to the same value; this row then shows what was dragged.
struct BoxEditor: View {
    let field: FormField
    @Binding var value: JSONValue?

    static let keys = [("x", "Left"), ("y", "Top"), ("width", "Width"), ("height", "Height")]

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: Tokens.Space.xs) {
                ForEach(Self.keys, id: \.0) { key, name in
                    TextField("\(name), percent of the picture", value: percent(key), format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden().textFieldStyle(.roundedBorder).frame(maxWidth: 56)
                        .help("\(name) (%)")
                }
                Text("%").foregroundStyle(Tokens.Color.secondaryLabel)
                Button { value = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).disabled(value == nil)
                    .accessibilityLabel("Clear \(field.label)")
            }
        }
    }

    /// One number of the box, as a percentage. Typing into an empty box starts from the whole picture.
    func percent(_ key: String) -> Binding<Double?> {
        Binding(get: { value?[key]?.numberValue.map { ($0 * 1000).rounded() / 10 } },
                set: { new in
                    var box = value?.objectValue ?? SubjectBox(x: 0, y: 0, width: 1, height: 1).json.objectValue ?? [:]
                    box[key] = .number((new ?? 0) / 100)
                    value = .object(box)
                })
    }
}

// MARK: - The box drawn on the picture

/// The `box` widget (Base §6.1, RFC 0009): a picture a person drags a rectangle on, for a parameter shaped
/// `{x, y, width, height}` in shares of the upright image, such as Mesh's `subject_box`. A host puts it on its image
/// well, bound to the form's value:
///
///     ImageBoxPicker(file: picture, box: Binding(get: { form.value(at: ["subject_box"]) },
///                                                set: { form.setValue($0, at: ["subject_box"]) }))
///
/// The picture is shown upright (its orientation tag applied), which is the image the shares are of (Image §1.1).
public struct ImageBoxPicker: View {
    let image: CGImage
    @Binding var box: JSONValue?
    @State private var dragging: SubjectBox?

    public init(image: CGImage, box: Binding<JSONValue?>) {
        self.image = image
        _box = box
    }

    /// Nil when the file isn't an image ImageIO reads.
    public init?(file: URL, box: Binding<JSONValue?>) {
        guard let image = Self.upright(file) else { return nil }
        self.init(image: image, box: box)
    }

    public var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(CGFloat(image.width) / CGFloat(max(1, image.height)), contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        if let shown = dragging ?? SubjectBox(box) {
                            let rect = Self.rect(shown, in: geo.size)
                            Rectangle().fill(Color.accentColor.opacity(0.15))
                                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in dragging = Self.box(from: g.startLocation, to: g.location, in: geo.size) }
                        .onEnded { g in
                            dragging = nil
                            if let made = Self.box(from: g.startLocation, to: g.location, in: geo.size) { box = made.json }
                        })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control))
            .accessibilityElement()
            .accessibilityLabel(SubjectBox(box).map { b in
                "Picture. The box starts \(Int(b.x * 100)) percent from the left and \(Int(b.y * 100)) from the top, "
                    + "\(Int(b.width * 100)) percent wide and \(Int(b.height * 100)) tall."
            } ?? "Picture. Drag to draw a box around where the part is.")
    }

    /// The box two corners of a drag make, in shares of a picture shown at `size`: kept inside the picture, and nil when
    /// it is under a hundredth of the picture either way (a click, not a box).
    public static func box(from a: CGPoint, to b: CGPoint, in size: CGSize) -> SubjectBox? {
        guard size.width > 0, size.height > 0 else { return nil }
        func share(_ v: CGFloat, _ of: CGFloat) -> Double { Double(min(max(v / of, 0), 1)) }
        let x0 = share(min(a.x, b.x), size.width), x1 = share(max(a.x, b.x), size.width)
        let y0 = share(min(a.y, b.y), size.height), y1 = share(max(a.y, b.y), size.height)
        guard x1 - x0 >= 0.01, y1 - y0 >= 0.01 else { return nil }
        return SubjectBox(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    static func rect(_ box: SubjectBox, in size: CGSize) -> CGRect {
        CGRect(x: box.x * size.width, y: box.y * size.height, width: box.width * size.width, height: box.height * size.height)
    }

    /// The file's image with its orientation tag applied, at most 2048 pixels a side: what the shares are of.
    public static func upright(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2048]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
