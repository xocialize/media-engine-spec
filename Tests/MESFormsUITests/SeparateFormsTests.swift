import Foundation
import MESCore
@testable import MESFormsUI
@testable import MockEngineCore
import SwiftUI
import Testing

// MESFormsUI for RFC 0006: audio.separate's stems and speaker pick, and edit_speech's edit, follow what the request's
// offers take, and the form says what an engine would refuse before it's sent.

func strings(_ widget: FieldWidget) -> [String] {
    switch widget {
    case .picker(let o), .multiPicker(let o): o.compactMap(\.stringValue)
    case .choice(let v): v.map(\.title)
    case .object(let f): f.map(\.name)
    default: []
    }
}

@Suite("MESFormsUI: separation and AuK's edits", .serialized)
@MainActor
struct SeparateFormsTests {
    @Test("separate: stems is a multi-picker and speaker a choice by order or by words; both follow the offers")
    func separateFields() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.separate"))
        for f in allFields(form.fields) { #expect(f.widget != .json, "audio.separate.\(f.name) fell back to JSON") }
        #expect(strings(field(form.fields, "stems").widget) == AudioProfile.stems)
        #expect(strings(field(form.fields, "speaker").widget) == ["By order", "By words"])
        // No model chosen: the offers the engine may pick (the default masked separator, the fast voice separator).
        #expect(strings(form.narrowed(field(form.fields, "stems")).widget) == ["speaker", "singing", "vocals", "instrumental"])
        let words = form.narrowed(field(form.fields, "speaker"))
        #expect(strings(words.widget) == ["By words"])
        if case .choice(let variants) = words.widget { #expect(variants.map(\.id) == [0]) }
        form.model = "mock-separator-voices"
        #expect(strings(form.narrowed(field(form.fields, "stems")).widget) == ["speaker", "singing", "voices"])
        #expect(strings(form.narrowed(field(form.fields, "speaker")).widget) == ["By order", "By words"])
        form.model = "mock-separator"
        #expect(strings(form.narrowed(field(form.fields, "speaker")).widget) == [])
        #expect(render(OperationFormContent(form: form)).height > 100)
    }

    @Test("separate: the speaker stem without a pick, a pick without it, and a stem or pick the chosen model lacks are issues")
    func separateIssues() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.separate"))
        form.setValue(["speaker"], at: ["stems"])
        #expect(form.issues["speaker"]?.contains("Say which speaker") == true)
        form.setValue(["ordinal": 2], at: ["speaker"])
        #expect(form.issues["speaker"] == nil)
        form.model = "mock-separator-flash"
        #expect(form.issues["speaker"]?.contains("by order") == true)
        form.setValue(["vocals"], at: ["stems"])
        form.setValue(["saying": "hello"], at: ["speaker"])
        #expect(form.issues["speaker"]?.contains("for the speaker stem") == true)
        #expect(form.issues["stems"] == "Mock fast voice separator doesn't make vocals.")
        form.setValue(nil, at: ["speaker"])
        form.setValue(["speaker", "singing"], at: ["stems"])
        form.setValue(["saying": "hello"], at: ["speaker"])
        #expect(form.issues.isEmpty, "\(form.issues)")
        #expect(form.request().params?["stems"] == ["speaker", "singing"])
    }

    @Test("edit_speech: the edit shows its kind, then that kind's fields, narrowed to the model's labels and cue placements")
    func editFields() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.edit_speech"))
        let edit = { form.narrowed(field(form.fields, "edit")).widget }
        #expect(strings(edit()) == ["kind"])
        form.model = "mock-editor-research"
        guard case .object(let fields) = edit() else { Issue.record("edit isn't an object"); return }
        #expect(strings(field(fields, "kind").widget).contains("dereverb"))
        form.setValue("add_cue", at: ["edit", "kind"])
        guard case .object(let cue) = edit() else { return }
        #expect(Set(strings(edit())) == ["kind", "cue", "at"], "edge only: no inline text")
        #expect(strings(field(cue, "cue").widget) == ["breath", "laugh", "cough", "hum"].filter { AudioProfile.cues.contains($0) }.sorted {
            AudioProfile.cues.firstIndex(of: $0)! < AudioProfile.cues.firstIndex(of: $1)!
        })
        #expect(field(cue, "cue").required && !field(cue, "at").required)
        form.model = nil                                      // the default editor places cues anywhere
        #expect(Set(strings(edit())) == ["kind", "cue", "at", "text"])
        form.setValue("dereverb", at: ["edit", "kind"])
        #expect(strings(edit()) == ["kind"])
    }

    @Test("edit_speech: removing every cue, fitting to a length and an unlisted kind are issues on a model that can't")
    func editIssues() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.edit_speech"))
        form.model = "mock-editor-research"
        form.setValue(["kind": "remove_cue"], at: ["edit"])
        #expect(form.issues["edit"]?.contains("one kind of sound at a time") == true)
        form.setValue("hum", at: ["edit", "cue"])
        #expect(form.issues["edit"] == nil)
        form.setValue(1.5, at: ["target_duration_s"])
        #expect(form.issues["target_duration_s"] == nil)
        form.model = "mock-editor"
        #expect(form.issues["target_duration_s"] == "Mock speech editor can't fit an edit to a length.")
        #expect(form.issues["edit"] == "Mock speech editor doesn't take a remove cue edit.")
    }
}
