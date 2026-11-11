import Foundation
import MESCore
@testable import MESFormsUI
@testable import MockEngineCore
import SwiftUI
import Testing

// MESFormsUI for RFC 0008: audio.separate's description and spans show only for offers that take them, the stems
// follow whether a sound is described, and the form says what an engine would refuse before it's sent.

@Suite("MESFormsUI: separating a described sound", .serialized)
@MainActor
struct DescribedTargetFormsTests {
    @Test("describe is a text field with the few-words hint, and spans a spans editor; neither falls back to JSON")
    func widgets() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.separate"))
        let describe = field(form.fields, "describe")
        #expect(describe.widget == .text && describe.label == "Sound to separate")
        #expect(describe.help == "Name the sound in a few words: speech, dog barking. Sentences don't work.")
        #expect(field(form.fields, "spans").widget == .spans)
        for f in allFields(form.fields) { #expect(f.widget != .json, "audio.separate.\(f.name) fell back to JSON") }
    }

    @Test("The description shows only where an offer separates a described sound, and spans only beside a description")
    func shows() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.separate"))
        let describe = field(form.fields, "describe"), spans = field(form.fields, "spans"), stems = field(form.fields, "stems")
        // No model: an offer the engine may pick takes a description. Spans wait for one.
        #expect(form.shows(describe) && !form.shows(spans) && form.shows(stems))
        #expect(strings(form.narrowed(stems).widget) == ["speaker", "singing", "vocals", "instrumental"])
        form.setValue("dog barking", at: ["describe"])
        #expect(form.shows(spans))
        #expect(strings(form.narrowed(stems).widget) == ["target", "residual"])
        #expect(form.issues.isEmpty, "\(form.issues)")
        // A model that takes neither: both fields go, once cleared.
        form.setValue(nil, at: ["describe"])
        form.model = "mock-separator"
        #expect(!form.shows(describe) && !form.shows(spans))
        #expect(strings(form.narrowed(stems).widget) == ["vocals", "instrumental"])
        form.model = "mock-separator-described"
        #expect(form.shows(describe) && strings(form.narrowed(stems).widget) == [])
        #expect(render(OperationFormContent(form: form)).height > 100)
        form.setValue("speech", at: ["describe"])
        form.setValue([["start_s": 0, "end_s": 1, "present": true], ["start_s": 1, "end_s": 2, "present": false]], at: ["spans"])
        #expect(render(OperationFormContent(form: form)).height > 100)
        #expect(form.request().params?["describe"] == "speech" && form.request().params?["spans"]?.arrayValue?.count == 2)
    }

    @Test("What an engine would refuse is said first: no description, a description on the wrong model, mixed stems, bad spans")
    func issues() async {
        let form = OperationFormModel(descriptor: await audioDescriptor("audio.separate"))
        form.model = "mock-separator-described"
        #expect(form.issues["describe"] == "Mock described-sound separator separates a sound you describe: say which.")
        form.setValue(["target"], at: ["stems"])
        #expect(form.issues["describe"]?.contains("need a description") == true)
        form.setValue("speech", at: ["describe"])
        #expect(form.issues.isEmpty, "\(form.issues)")
        // Spans: backwards, overlapping, then sound.
        form.setValue([["start_s": 2, "end_s": 1, "present": true]], at: ["spans"])
        #expect(form.issues["spans"]?.contains("ends after it starts") == true)
        form.setValue([["start_s": 0, "end_s": 2, "present": true], ["start_s": 1, "end_s": 3, "present": false]], at: ["spans"])
        #expect(form.issues["spans"]?.contains("overlap") == true)
        form.setValue([["start_s": 0, "end_s": 1, "present": true]], at: ["spans"])
        #expect(form.issues.isEmpty, "\(form.issues)")
        // Spans left behind without their description still show, with why.
        form.setValue(nil, at: ["describe"])
        form.setValue(nil, at: ["stems"])
        #expect(form.shows(field(form.fields, "spans")) && form.issues["spans"]?.contains("describe the sound too") == true)
        // The wrong model: a description it can't take stays visible and says so; a labelled stem beside one is flagged.
        form.setValue(nil, at: ["spans"])
        form.setValue("speech", at: ["describe"])
        form.model = "mock-separator"
        #expect(form.shows(field(form.fields, "describe")))
        #expect(form.issues["describe"] == "Mock music separator doesn't separate a described sound.")
        form.setValue(["vocals"], at: ["stems"])
        #expect(form.issues["stems"]?.contains("clear vocals") == true)
        form.model = nil
        form.setValue(nil, at: ["stems"])
        form.setValue(["saying": "hello"], at: ["speaker"])
        #expect(form.issues["speaker"]?.contains("not for a described sound") == true)
    }

    @Test("A new span starts where the last one ends; an offer's watermark shows on its model row")
    func spansAndWatermark() async {
        #expect(SpansEditor.next(after: []) == ["start_s": 0, "end_s": 1, "present": true])
        #expect(SpansEditor.next(after: [["start_s": 0, "end_s": 2.5, "present": false]]) == ["start_s": 2.5, "end_s": 3.5, "present": true])
        let d = await audioDescriptor("audio.separate")
        let described = d.models.first { $0.id == "mock-separator-described" }!
        #expect(described.watermark == "mock-mark" && ModelRow.detail(described).hasSuffix("watermarked (mock-mark)"))
        #expect(!ModelRow.detail(d.models[0]).contains("watermarked"))
    }
}
