import Foundation
import Observation
import OSLog

/// Thin client for an OpenAI-compatible local LLM server (omlx). For now it
/// covers connection probing + model discovery, which is what the Settings
/// screen needs; the chat-completion calls for the finalize/regenerate pipeline
/// will sit on top of the same `Config` request builder later.
///
/// The LLM features are an optional add-on, so nothing here throws into the UI
/// as fatal: `refresh` records the outcome in `status` for the settings
/// indicator, and pipeline callers treat an unreachable server as "skip the
/// extra step."
@Observable
@MainActor
final class LLMClient {
    /// Connection state surfaced by the Settings indicator.
    enum Status: Equatable {
        case idle
        case checking
        case connected
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Model ids advertised by the server's `/v1/models`, for the picker.
    private(set) var models: [String] = []

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "llm")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Probe `{baseURL}/v1/models` to confirm the server is up and the key is
    /// valid, and load the model list. Never throws — the outcome lands in
    /// `status` (and `models` on success) for the Settings UI to render.
    func refresh(config: LLMSettings.Config) async {
        guard config.isConfigured else {
            models = []
            status = .idle
            return
        }
        status = .checking
        do {
            let ids = try await fetchModels(config: config)
            models = ids
            status = .connected
            Self.log.notice("LLM server connected: \(ids.count) models")
        } catch {
            models = []
            let message = Self.describe(error)
            status = .failed(message)
            Self.log.error("LLM server probe failed: \(message, privacy: .public)")
        }
    }

    /// GET `{baseURL}/v1/models`, returning the sorted model ids.
    func fetchModels(config: LLMSettings.Config) async throws -> [String] {
        let request = try Self.makeRequest(config: config, path: "v1/models", timeout: 10)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.noResponse }
        guard http.statusCode == 200 else {
            throw LLMError.http(http.statusCode, Self.serverMessage(data))
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id).sorted()
    }

    // MARK: - Request building

    /// Build a request against `{baseURL}/{path}` with the bearer key attached
    /// when present. Shared by the model probe and (later) chat completions.
    static func makeRequest(
        config: LLMSettings.Config, path: String, timeout: TimeInterval
    ) throws -> URLRequest {
        let trimmed = config.baseURL.trimmingCharacters(in: .whitespaces)
        guard let base = URL(string: trimmed) else { throw LLMError.badURL }
        var request = URLRequest(url: base.appending(path: path))
        request.timeoutInterval = timeout
        let key = config.apiKey.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Error shaping

    private static func describe(_ error: Error) -> String {
        if let llm = error as? LLMError { return llm.message }
        if let url = error as? URLError {
            switch url.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                .notConnectedToInternet:
                return "Can't reach server"
            case .timedOut:
                return "Timed out"
            default:
                return url.localizedDescription
            }
        }
        return error.localizedDescription
    }

    /// Pull the human message out of an OpenAI-style `{"error":{"message":…}}`.
    private static func serverMessage(_ data: Data) -> String? {
        struct Envelope: Decodable {
            struct Payload: Decodable { let message: String }
            let error: Payload
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error.message
    }
}

/// Errors mapped to user-facing strings for the Settings indicator.
enum LLMError: Error {
    case badURL
    case noResponse
    case http(Int, String?)

    var message: String {
        switch self {
        case .badURL: return "Invalid server URL"
        case .noResponse: return "No response from server"
        case .http(401, _), .http(403, _): return "Invalid API key"
        case .http(let code, let message): return message ?? "Server error (\(code))"
        }
    }
}

/// `/v1/models` response shape.
private struct ModelsResponse: Decodable {
    struct Model: Decodable { let id: String }
    let data: [Model]
}
