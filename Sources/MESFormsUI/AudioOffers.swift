import Foundation
import MESCore

/// Audio forms that follow the offers (Audio §3.3, §3.6, §4.1; RFC 0006): `separate`'s stems and speaker picks, and
/// `edit_speech`'s edit, show only what the request's offers take, and the form says what an engine would refuse
/// before it is sent: the speaker stem without a pick, a stem or edit the chosen model doesn't make, an edit fitted to a
/// length on a model that can't, every cue removed by a model that removes one kind at a time.
extension OperationFormModel {
    typealias AP = AudioProfile.Param
    typealias AK = AudioProfile.SupportsKey

    /// The offers the request may run on: the chosen model; with none chosen, every offer the engine may pick (all of
    /// them when every offer is `named_only`, so the form still shows what exists).
    var candidateOffers: [ModelOffer] {
        if let model, let chosen = descriptor.models.first(where: { $0.id == model }) { return [chosen] }
        let pickable = descriptor.models.filter { $0.namedOnly != true }
        return pickable.isEmpty ? descriptor.models : pickable
    }

    /// The values of a list key across the candidate offers; an offer without the key counts as `absent`.
    func offered(_ key: String, absent: [String]) -> Set<String> {
        Set(candidateOffers.flatMap { $0.supports(key)?.arrayValue?.compactMap(\.stringValue) ?? absent })
    }

    /// A top-level field as the request's offers take it. Fields of other profiles, and other fields, are unchanged.
    public func narrowed(_ field: FormField) -> FormField {
        guard descriptor.profile == AudioProfile.id else { return field }
        var f = field
        switch (descriptor.operation, field.name, field.widget) {
        case ("audio.separate", AP.stems, .multiPicker(let options)):
            let made = offered(AK.stems, absent: [])
            f.widget = .multiPicker(options.filter { $0.stringValue.map(made.contains) ?? false })
        case ("audio.separate", AP.speaker, .choice(let variants)):
            let kinds = offered(AK.speakerSelection, absent: [])
            f.widget = .choice(variants
                .filter { v in (v.schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []).contains(where: kinds.contains) }
                .enumerated().map { i, v in var v = v; v.id = i; return v })
        case ("audio.edit_speech", AP.edit, .object(let fields)):
            f.widget = .object(editFields(fields))
        default:
            break
        }
        return f
    }

    /// The edit's fields for the kind chosen: the kind, then the fields that kind takes (§3.3), each picker narrowed to
    /// the offers' labels. An `add_cue` shows `at` only where an offer places cues at an edge, and `text` only where
    /// one places them inline.
    func editFields(_ fields: [FormField]) -> [FormField] {
        func narrow(_ f: FormField, to allowed: Set<String>, required: Bool) -> FormField {
            var f = f
            if case .picker(let options) = f.widget { f.widget = .picker(options.filter { $0.stringValue.map(allowed.contains) ?? false }) }
            f.required = required
            return f
        }
        guard var kindField = fields.first(where: { $0.name == "kind" }) else { return fields }
        kindField = narrow(kindField, to: offered(AK.edits, absent: []), required: true)
        guard let kind = value(at: [AP.edit, "kind"])?.stringValue else { return [kindField] }
        let needed = AudioProfile.editFields[kind] ?? []
        var optional = AudioProfile.editOptionalFields[kind] ?? []
        if kind == "add_cue" {
            let placements = offered(AK.cuePlacement, absent: AudioProfile.cuePlacements)
            optional.removeAll { ($0 == "at" && !placements.contains("edge")) || ($0 == "text" && !placements.contains("inline")) }
        }
        let labels: [String: Set<String>] = ["emotion": offered(AK.emotions, absent: []), "style": offered(AK.styles, absent: []),
                                             "cue": offered(AK.cues, absent: [])]
        let rest = fields.filter { needed.contains($0.name) || optional.contains($0.name) }.map { f in
            labels[f.name].map { narrow(f, to: $0, required: needed.contains(f.name)) } ?? {
                var f = f
                f.required = needed.contains(f.name)
                return f
            }()
        }
        return [kindField] + rest
    }

    /// What an engine would refuse in the Audio fields, said before sending (§3.3, §3.6, §4.1), by parameter.
    var audioIssues: [String: String] {
        guard descriptor.profile == AudioProfile.id else { return [:] }
        var out: [String: String] = [:]
        let chosen = model == nil ? nil : effectiveModel
        func list(_ m: ModelOffer, _ key: String) -> [String] { m.supports(key)?.arrayValue?.compactMap(\.stringValue) ?? [] }
        switch descriptor.operation {
        case "audio.separate":
            let stems = values[AP.stems]?.arrayValue?.compactMap(\.stringValue)
            let pick = values[AP.speaker]
            if stems?.contains("speaker") == true, pick == nil {
                out[AP.speaker] = "Say which speaker to keep: by order, or by words they say."
            } else if let stems, pick != nil, !stems.contains("speaker") {
                out[AP.speaker] = "A speaker pick is for the speaker stem: add it to the stems, or clear the pick."
            }
            if let m = chosen, let stems {
                let missing = stems.filter { !list(m, AK.stems).contains($0) }
                if !missing.isEmpty { out[AP.stems] = "\(m.title) doesn't make \(missing.joined(separator: ", "))." }
            }
            if let m = chosen, let kind = pick?.objectValue?.keys.first(where: AudioProfile.speakerSelections.contains),
               !list(m, AK.speakerSelection).contains(kind), out[AP.speaker] == nil {
                out[AP.speaker] = "\(m.title) can't pick a speaker \(kind == "ordinal" ? "by order" : "by words")."
            }
        case "audio.edit_speech":
            guard let m = chosen else { break }
            let edit = values[AP.edit]?.objectValue
            if let kind = edit?["kind"]?.stringValue, !list(m, AK.edits).contains(kind) {
                out[AP.edit] = "\(m.title) doesn't take a \(FormSchema.display(.string(kind)).lowercased()) edit."
            } else if edit?["kind"]?.stringValue == "remove_cue", edit?["cue"] == nil, m.supports(AK.removeAllCues)?.boolValue == false {
                out[AP.edit] = "\(m.title) removes one kind of sound at a time: choose the cue."
            }
            if values[AP.targetDuration] != nil, m.supports(AK.targetDuration)?.boolValue != true {
                out[AP.targetDuration] = "\(m.title) can't fit an edit to a length."
            }
        default:
            break
        }
        return out
    }
}
