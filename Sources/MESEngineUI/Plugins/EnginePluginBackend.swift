import Foundation
import MESCore

/// What an engine whose models come as plugins gives its console's Plugins page. Gaea implements it over its plugin
/// manager: plugins are added by Git repo URL and found through that repo's releases (G-18), and only a signature from
/// a trusted team lets one run, never the URL (G-7). MESEngineUI shows the page when a console is attached with one.
///
/// Turning a plugin's models on and off stays with `EngineConsoleBackend.setEnabled(_:model:)`.
public protocol EnginePluginBackend: Sendable {
    /// Every installed plugin, on or off.
    func plugins() async -> [EnginePlugin]

    /// The teams whose signatures the engine accepts.
    func trustedTeams() async -> [EngineTrustedTeam]

    /// Adds a plugin from a Git repo URL: finds its newest compatible release, downloads it and checks its checksum and
    /// signature. A plugin signed by a team that isn't trusted yet isn't installed: the outcome asks the operator first.
    /// `progress` is 0–1.
    func add(repository: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> PluginInstallOutcome

    /// Trusts the request's team and finishes the install or update that asked for it.
    func trust(_ request: PluginTrustRequest, progress: @escaping @Sendable (Double) -> Void) async throws

    /// The operator declined to trust the request's team: drops what was downloaded.
    func decline(_ request: PluginTrustRequest) async

    /// Updates a plugin to `update.version`. The engine switches to it when the plugin's models are idle and keeps the
    /// version it replaces, for rolling back. A release signed by another team asks for trust like an add.
    func update(plugin id: String, to update: EngineUpdate,
                progress: @escaping @Sendable (Double) -> Void) async throws -> PluginInstallOutcome

    /// Switches back to the version kept on disk (`EnginePlugin.rollbackVersion`).
    func rollBack(plugin id: String) async throws

    /// Switches a whole plugin on or off and saves the choice. Off, none of its models is offered and its worker stops.
    func setEnabled(_ enabled: Bool, plugin id: String) async throws

    /// Reads every plugin's repo for newer releases now, instead of on the engine's own schedule.
    func checkForUpdates() async throws

    /// Removes a plugin and its versions on disk.
    func remove(plugin id: String) async throws

    /// Stops trusting a team. Its plugins stop running until it's trusted again.
    func revokeTrust(team id: String) async throws
}

extension EnginePluginBackend {
    public func decline(_ request: PluginTrustRequest) async {}
    public func checkForUpdates() async throws {}
    public func remove(plugin id: String) async throws {
        throw MESError(.engineError, "This engine doesn't remove plugins.")
    }
    public func revokeTrust(team id: String) async throws {
        throw MESError(.engineError, "This engine doesn't change its trusted teams here.")
    }
}

/// What adding or updating a plugin came to.
public enum PluginInstallOutcome: Sendable, Equatable {
    /// Installed (or, for an update, staged to switch to when idle).
    case installed(EnginePlugin)
    /// Signed by a team the engine doesn't trust yet: nothing is installed until the operator answers.
    case needsTrust(PluginTrustRequest)
}

/// A team that signs plugins: an Apple Developer ID team.
public struct EngineTeam: Sendable, Equatable, Hashable, Identifiable {
    /// The Team ID, e.g. `CFZS6RXUCP`.
    public var id: String
    /// The name on the certificate.
    public var name: String

    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// A team on the engine's trust list.
public struct EngineTrustedTeam: Sendable, Equatable, Identifiable {
    public var team: EngineTeam
    /// Trusted by the engine itself (its own team), so it can't be removed.
    public var builtIn: Bool
    /// When the operator added it.
    public var addedAt: Date?
    public var id: String { team.id }

    public init(team: EngineTeam, builtIn: Bool = false, addedAt: Date? = nil) {
        self.team = team; self.builtIn = builtIn; self.addedAt = addedAt
    }
}

/// A plugin signed by a team the engine doesn't trust yet, waiting for the operator's answer.
public struct PluginTrustRequest: Sendable, Equatable, Identifiable {
    /// The engine's handle for the pending install.
    public var id: String
    public var team: EngineTeam
    public var pluginID: String
    public var pluginTitle: String
    public var version: String
    public var repository: URL
    /// The signing certificate's common name, e.g. "Developer ID Application: Jane Doe (ABCDE12345)".
    public var signingIdentity: String?
    /// Whether Apple notarized the bundle.
    public var notarized: Bool
    /// The models it would add.
    public var models: [String]

    public init(id: String, team: EngineTeam, pluginID: String, pluginTitle: String, version: String, repository: URL,
                signingIdentity: String? = nil, notarized: Bool, models: [String] = []) {
        self.id = id; self.team = team; self.pluginID = pluginID; self.pluginTitle = pluginTitle; self.version = version
        self.repository = repository; self.signingIdentity = signingIdentity; self.notarized = notarized; self.models = models
    }
}

/// One installed plugin, as the Plugins page shows it.
public struct EnginePlugin: Sendable, Equatable, Identifiable {
    public enum State: Sendable, Equatable {
        case ready
        /// Downloading or verifying a new version.
        case updating(fraction: Double?)
        /// A new version is installed and the engine switches to it when the plugin's models are idle.
        case pendingSwitch(version: String)
        /// It can't run, e.g. its team was removed from the trust list or its signature failed.
        case failed(String)
    }

    /// The manifest's id, e.g. `com.xocialize.gaea.z-image`.
    public var id: String
    public var title: String
    /// A sentence on what it adds.
    public var summary: String
    /// The Git repo it was added from, and whose releases it updates from.
    public var repository: URL
    /// The version in use.
    public var version: String
    /// The version kept on disk for rolling back, if any.
    public var rollbackVersion: String?
    /// A newer compatible release, if the last check found one.
    public var update: EngineUpdate?
    public var team: EngineTeam
    public var enabled: Bool
    public var state: State
    /// The ids of the models it provides (`EngineModel.id`).
    public var models: [String]
    /// When its repo was last read for releases.
    public var lastChecked: Date?

    public init(id: String, title: String, summary: String = "", repository: URL, version: String,
                rollbackVersion: String? = nil, update: EngineUpdate? = nil, team: EngineTeam, enabled: Bool = true,
                state: State = .ready, models: [String] = [], lastChecked: Date? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.repository = repository; self.version = version
        self.rollbackVersion = rollbackVersion; self.update = update; self.team = team; self.enabled = enabled
        self.state = state; self.models = models; self.lastChecked = lastChecked
    }
}
