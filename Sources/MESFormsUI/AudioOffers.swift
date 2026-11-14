import Foundation
import MESCore

/// Audio forms that follow the offers (Audio §3.3, §3.6, §4.1; RFCs 0006 and 0008): `separate`'s stems, speaker picks,
/// description and spans, and `edit_speech`'s edit, show only what the request's offers take, and the form says what an
/// engine would refuse before it is sent: the speaker stem without a pick, a stem or edit the chosen model doesn't make,
/// a description or spans on a model that takes none, an edit fitted to a length on a model that can't, every cue
/// removed by a model that removes one kind at a time.
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

    /// Whether a candidate offer states a boolean key.
    func anyOffer(_ key: String) -> Bool { candidateOffers.contains { $0.supports(key)?.boolValue == true } }

    /// Whether the form has a description of the sound to separate (RFC 0008).
    var describes: Bool { values[AP.describe] != nil }

    /// Whether a top-level field belongs on the form for the request's offers (RFC 0008). `separate`'s description
    /// shows only where an offer separates a described sound, and its spans only where one takes spans and a
    /// description is given. A field that holds a value always shows, so what an engine would refuse can be seen and
    /// cleared. Every other field shows.
    public func shows(_ field: FormField) -> Bool {
        if descriptor.profile == MeshProfile.id { return meshShows(field) }
        guard descriptor.operation == "audio.separate", values[field.name] == nil else { return true }
        switch field.name {
        case AP.describe: return anyOffer(AK.describedTarget)
        case AP.spans: return describes && anyOffer(AK.spans)
        default: return true
        }
    }

    /// A top-level field as the request's offers take it. Fields of other profiles, and other fields, are unchanged.
    public func narrowed(_ field: FormField) -> FormField {
        if descriptor.profile == MeshProfile.id { return meshNarrowed(field) }
        guard descriptor.profile == AudioProfile.id else { return field }
        var f = field
        switch (descriptor.operation, field.name, field.widget) {
        case ("audio.separate", AP.stems, .multiPicker(let options)):
            // The target and the residual are a description's stems, and a description takes no other (RFC 0008).
            let made = offered(AK.stems, absent: []).filter { AudioProfile.describedStems.contains($0) == describes }
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
            // RFC 0008: a described sound, its two stems and its spans.
            let described = AudioProfile.describedStems
            if describes {
                if let other = stems?.first(where: { !described.contains($0) }) {
                    out[AP.stems] = "A description separates the target and the residual: clear \(other), or clear the description."
                }
                if pick != nil { out[AP.speaker] = "A speaker pick is for the speaker stem, not for a described sound." }
                if let m = chosen, m.supports(AK.describedTarget)?.boolValue != true {
                    out[AP.describe] = "\(m.title) doesn't separate a described sound."
                }
            } else {
                if stems?.contains(where: described.contains) == true {
                    out[AP.describe] = "Say what sound to separate: the target and the residual need a description."
                } else if let m = chosen, stems == nil, pick == nil,
                          !list(m, AK.stems).contains(where: { $0 != "speaker" && !described.contains($0) }),
                          m.supports(AK.describedTarget)?.boolValue == true {
                    out[AP.describe] = "\(m.title) separates a sound you describe: say which."
                }
                if values[AP.spans] != nil { out[AP.spans] = "Spans say where a described sound is: describe the sound too." }
            }
            if let spans = SeparationSpan.list(values[AP.spans]), out[AP.spans] == nil {
                if let problem = SeparationSpan.problem(spans) {
                    out[AP.spans] = problem
                } else if let m = chosen, m.supports(AK.spans)?.boolValue != true {
                    out[AP.spans] = "\(m.title) doesn't take spans."
                }
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
