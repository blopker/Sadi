import Foundation

/// Settings keys + defaults for the optional LLM server integration — an
/// OpenAI-compatible local endpoint (e.g. omlx). Kept in one place, like
/// `AutoStopSettings`, so the Settings UI (`@AppStorage`) and the pipeline code
/// that calls the server agree on key names and defaults.
///
/// The LLM features are an opt-in add-on: when the server is unreachable the
/// extra finalize/regenerate steps simply no-op, so a missing or misconfigured
/// server degrades to "transcript only" rather than an error.
nonisolated enum LLMSettings {
    static let baseURLKey = "llm.baseURL"
    static let apiKeyKey = "llm.apiKey"
    static let modelKey = "llm.model"

    /// omlx's default listen address.
    static let defaultBaseURL = "http://localhost:8080"

    /// Resolved server configuration. A `nonisolated` value type so it crosses
    /// actor boundaries cleanly (the offline pipeline reads it off-main) and is
    /// easy to hand to the client's request builders.
    nonisolated struct Config: Equatable, Sendable {
        var baseURL: String
        var apiKey: String
        var model: String

        /// Whether there's enough configured to bother contacting the server.
        var isConfigured: Bool {
            !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    nonisolated static func current(_ defaults: UserDefaults = .standard) -> Config {
        Config(
            baseURL: defaults.string(forKey: baseURLKey) ?? defaultBaseURL,
            apiKey: defaults.string(forKey: apiKeyKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? ""
        )
    }

    /// `current()` when there's enough configuration to make chat requests
    /// (a base URL and a chosen model), `nil` otherwise. The single gate for
    /// the optional LLM pipeline stages — callers past this point can assume
    /// the config is usable.
    nonisolated static func currentIfConfigured(_ defaults: UserDefaults = .standard) -> Config? {
        let config = current(defaults)
        guard config.isConfigured, !config.model.isEmpty else { return nil }
        return config
    }
}
