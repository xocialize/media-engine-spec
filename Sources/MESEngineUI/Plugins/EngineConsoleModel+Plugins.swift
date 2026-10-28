import Foundation
import MESCore

// The Plugins page's actions. Each runs on the plugin backend, records progress in `pluginWork`, surfaces a failure in
// `actionError`, hands a trust question to `trustPrompt`, and refreshes plugins and models when it's done.
extension EngineConsoleModel {
    public func refreshPlugins() async {
        guard let pluginBackend else { return }
        async let plugins = pluginBackend.plugins()
        async let teams = pluginBackend.trustedTeams()
        let (p, t) = await (plugins, teams)
        if self.plugins != p { self.plugins = p }
        if trustedTeams != t { trustedTeams = t }
    }

    /// The models a plugin provides, as the Models page has them.
    func models(of plugin: EnginePlugin) -> [EngineModel] {
        models.filter { $0.plugin?.id == plugin.id || plugin.models.contains($0.id) }
    }

    func pluginTitle(_ id: String) -> String { plugins.first { $0.id == id }?.title ?? id }

    /// Reads `text` as a plugin repo URL: `https://github.com/owner/repo`, with or without `.git`, or `owner/repo`.
    static func repositoryURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://"), trimmed.split(separator: "/").count == 2, !trimmed.contains(" ") {
            return URL(string: "https://github.com/" + trimmed)
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host() != nil, url.pathComponents.filter({ $0 != "/" }).count >= 2 else { return nil }
        return url
    }

    /// Adds a plugin from its repo. Returns once the backend answers: installed, or waiting for trust (`trustPrompt`).
    /// Throws the backend's error, for the add sheet to show.
    func addPlugin(repository: URL) async throws {
        guard let pluginBackend else { return }
        let key = repository.absoluteString
        pluginWork[key] = .some(nil)
        defer { pluginWork[key] = nil }
        let outcome = try await pluginBackend.add(repository: repository, progress: progressHandler(key))
        await handle(outcome)
    }

    /// The progress of an add from `repository`: nil when none is running, `.some(nil)` while unknown.
    func addProgress(_ repository: URL) -> Double?? { pluginWork[repository.absoluteString] }

    func trust(_ request: PluginTrustRequest) {
        guard let pluginBackend else { return }
        trustPrompt = nil
        pluginWork[request.pluginID] = .some(nil)
        Task {
            do {
                try await pluginBackend.trust(request, progress: progressHandler(request.pluginID))
                selectedPluginID = request.pluginID
            } catch {
                actionError = "Couldn't install \(request.pluginTitle): \(Self.describe(error))"
            }
            pluginWork[request.pluginID] = nil
            await refreshAll()
        }
    }

    func decline(_ request: PluginTrustRequest) {
        trustPrompt = nil
        guard let pluginBackend else { return }
        Task { await pluginBackend.decline(request) }
    }

    func update(plugin: EnginePlugin) {
        guard let pluginBackend, let update = plugin.update, pluginWork[plugin.id] == nil else { return }
        pluginWork[plugin.id] = .some(nil)
        Task {
            do {
                let outcome = try await pluginBackend.update(plugin: plugin.id, to: update, progress: progressHandler(plugin.id))
                await handle(outcome)
            } catch {
                actionError = "Couldn't update \(plugin.title) to \(update.version): \(Self.describe(error))"
            }
            pluginWork[plugin.id] = nil
            await refreshAll()
        }
    }

    func rollBack(plugin: EnginePlugin) {
        guard let pluginBackend, pluginWork[plugin.id] == nil else { return }
        pluginWork[plugin.id] = .some(nil)
        Task {
            do {
                try await pluginBackend.rollBack(plugin: plugin.id)
            } catch {
                actionError = "Couldn't roll \(plugin.title) back: \(Self.describe(error))"
            }
            pluginWork[plugin.id] = nil
            await refreshAll()
        }
    }

    func setEnabled(_ enabled: Bool, plugin id: String) {
        guard let pluginBackend else { return }
        if let index = plugins.firstIndex(where: { $0.id == id }) { plugins[index].enabled = enabled }   // optimistic
        Task {
            do {
                try await pluginBackend.setEnabled(enabled, plugin: id)
            } catch {
                actionError = "Couldn't turn \(pluginTitle(id)) \(enabled ? "on" : "off"): \(Self.describe(error))"
            }
            await refreshAll()
        }
    }

    func checkForUpdates() {
        guard let pluginBackend, pluginWork["*"] == nil else { return }
        pluginWork["*"] = .some(nil)
        Task {
            do {
                try await pluginBackend.checkForUpdates()
            } catch {
                actionError = "Couldn't check for updates: \(Self.describe(error))"
            }
            pluginWork["*"] = nil
            await refreshAll()
        }
    }

    var isCheckingForUpdates: Bool { pluginWork["*"] != nil }

    func remove(plugin: EnginePlugin) {
        guard let pluginBackend else { return }
        Task {
            do {
                try await pluginBackend.remove(plugin: plugin.id)
                if selectedPluginID == plugin.id { selectedPluginID = nil }
            } catch {
                actionError = "Couldn't remove \(plugin.title): \(Self.describe(error))"
            }
            await refreshAll()
        }
    }

    func revokeTrust(team: EngineTeam) {
        guard let pluginBackend else { return }
        Task {
            do {
                try await pluginBackend.revokeTrust(team: team.id)
            } catch {
                actionError = "Couldn't remove \(team.name) from the trusted teams: \(Self.describe(error))"
            }
            await refreshAll()
        }
    }

    /// Plugins with an update waiting.
    var updatesAvailable: Int { plugins.filter { $0.update != nil }.count }

    // MARK: - Helpers

    private func handle(_ outcome: PluginInstallOutcome) async {
        switch outcome {
        case .installed(let plugin): selectedPluginID = plugin.id
        case .needsTrust(let request): trustPrompt = request
        }
        await refreshAll()
    }

    private func refreshAll() async {
        await refreshPlugins()
        await refreshModels()
    }

    private func progressHandler(_ key: String) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                if self?.pluginWork[key] != nil { self?.pluginWork[key] = .some(fraction) }
            }
        }
    }
}
