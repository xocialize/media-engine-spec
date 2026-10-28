import Foundation
import MESEngineCore
import Synchronization
import Testing

// ModelEnablement behind its storage protocol: the JSON file stays the default, and an engine can supply its own store
// (Gaea's is its database).

/// A store that keeps the choices in memory and counts its calls, standing in for a database.
final class RecordingStore: ModelEnablementStore {
    let saved: Mutex<ModelEnablement.Choices>
    let saves = Atomic(0)
    let failsToLoad: Bool

    init(_ initial: ModelEnablement.Choices = .init(), failsToLoad: Bool = false) {
        saved = Mutex(initial)
        self.failsToLoad = failsToLoad
    }

    func load() throws -> ModelEnablement.Choices {
        if failsToLoad { throw CocoaError(.fileReadCorruptFile) }
        return saved.withLock { $0 }
    }

    func save(_ choices: ModelEnablement.Choices) throws {
        saved.withLock { $0 = choices }
        saves.add(1, ordering: .relaxed)
    }
}

@Suite("ModelEnablement stores")
struct EnablementStoreTests {
    @Test("A custom store: loaded at init, saved after every change, and opt-in acceptance recorded")
    func customStore() throws {
        var initial = ModelEnablement.Choices()
        initial.disabled = ["flux"]
        let store = RecordingStore(initial)
        let enablement = try ModelEnablement(store: store)
        #expect(!enablement.isEnabled("flux", optIn: false))
        #expect(enablement.isEnabled("z-image", optIn: false))
        #expect(enablement.file == nil)

        try enablement.set("research", enabled: true, optIn: true)
        try enablement.set("flux", enabled: true, optIn: false)
        #expect(store.saves.load(ordering: .relaxed) == 2)
        let saved = store.saved.withLock { $0 }
        #expect(saved.enabled == ["research"])
        #expect(saved.disabled.isEmpty)
        #expect(saved.accepted["research"] != nil)

        // A second engine instance over the same store sees the choices.
        let reopened = try ModelEnablement(store: store)
        #expect(reopened.isEnabled("research", optIn: true))
        #expect(reopened.acceptedAt("research") == saved.accepted["research"])
    }

    @Test("A store that can't load throws from init(store:) rather than silently starting over")
    func failingStore() {
        #expect(throws: CocoaError.self) { _ = try ModelEnablement(store: RecordingStore(failsToLoad: true)) }
    }

    @Test("The JSON file is still the default: init(file:) round-trips, and a missing file starts from the defaults")
    func jsonFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("enablement-\(UUID().uuidString)/models.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let first = ModelEnablement(file: file)
        #expect(first.file == file)
        #expect(first.choices == ModelEnablement.Choices())
        try first.set("a", enabled: false, optIn: false)
        try first.set("b", enabled: true, optIn: true)

        let viaStore = try ModelEnablement(store: JSONFileEnablementStore(file: file))
        #expect(!viaStore.isEnabled("a", optIn: false))
        #expect(viaStore.isEnabled("b", optIn: true))
        // ISO 8601 keeps whole seconds, so compare the acceptance date to the second.
        #expect(viaStore.choices.disabled == first.choices.disabled && viaStore.choices.enabled == first.choices.enabled)
        let accepted = try #require(viaStore.acceptedAt("b")), original = try #require(first.acceptedAt("b"))
        #expect(abs(accepted.timeIntervalSince(original)) < 1)
        // The file is the same JSON as before the store protocol existed.
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["accepted", "disabled", "enabled"])

        // Memory only.
        let memory = ModelEnablement(file: nil)
        try memory.set("x", enabled: false, optIn: false)
        #expect(memory.store == nil && !memory.isEnabled("x", optIn: false))
    }
}
