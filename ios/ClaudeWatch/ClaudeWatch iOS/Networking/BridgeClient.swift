import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A cmux terminal screen plus its hash (for safe approval responses).
struct CmuxScreen {
    let text: String
    let hash: String?
}

/// Result of a guarded cmux input send.
enum CmuxSendResult {
    case sent
    case screenChanged(text: String, hash: String?)
    case failed(String)
}

/// HTTP client for communicating with the Agent iPhone bridge server.
final class BridgeClient {

    // MARK: - Errors

    enum BridgeError: LocalizedError {
        case invalidCode
        case expired
        case rateLimited
        case networkError
        case screenChanged
        case serverError(String)

        var errorDescription: String? {
            switch self {
            case .invalidCode:      return "Invalid pairing code."
            case .expired:          return "Pairing code expired."
            case .rateLimited:      return "Too many attempts. Try again later."
            case .networkError:     return "Cannot reach bridge server."
            case .screenChanged:    return "Screen changed before the answer landed."
            case .serverError(let msg): return msg
            }
        }
    }

    // MARK: - Properties

    private(set) var baseURL: URL?
    private(set) var token: String?

    private let session: URLSession

    // MARK: - Init

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)

        // Restore saved token
        self.token = UserDefaults.standard.string(forKey: "bridge_token")
        if let saved = UserDefaults.standard.string(forKey: "bridge_url") {
            self.baseURL = URL(string: saved)
        }
    }

    // MARK: - Configuration

    func configure(host: String, port: UInt16) {
        let urlString = "http://\(host):\(port)"
        self.baseURL = URL(string: urlString)
        UserDefaults.standard.set(urlString, forKey: "bridge_url")
    }

    /// Switch the active bridge to an already-paired Mac (host/port/token known).
    /// Used by the Macs switcher — no pairing round-trip.
    func applyActive(host: String, port: UInt16, token: String) {
        let urlString = "http://\(host):\(port)"
        self.baseURL = URL(string: urlString)
        self.token = token
        UserDefaults.standard.set(urlString, forKey: "bridge_url")
        UserDefaults.standard.set(token, forKey: "bridge_token")
    }

    var isPaired: Bool {
        token != nil && baseURL != nil
    }

    func clearCredentials() {
        token = nil
        baseURL = nil
        UserDefaults.standard.removeObject(forKey: "bridge_token")
        UserDefaults.standard.removeObject(forKey: "bridge_url")
    }

    // MARK: - Pairing

    /// A stable per-install device id (persisted) + a display name, sent at pair
    /// time so each device gets its own revocable token on the bridge.
    static func deviceIdentity() -> (id: String, name: String) {
        let key = "agentiphone_device_id"
        let id: String
        if let existing = UserDefaults.standard.string(forKey: key) {
            id = existing
        } else {
            id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
        }
        #if canImport(UIKit)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? "iPhone"
        #endif
        return (id, name)
    }

    /// Pairs with the bridge using a 6-digit code.
    /// On success, stores the session token.
    @discardableResult
    func pair(code: String) async throws -> String {
        guard let baseURL else {
            throw BridgeError.networkError
        }

        let url = baseURL.appendingPathComponent("pair")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Send a stable per-install device id + name so the bridge tracks this
        // device individually (re-pairing replaces it, not duplicates) and
        // `agent-iphone pair --list` shows a real name.
        let dev = Self.deviceIdentity()
        request.httpBody = try JSONEncoder().encode(["code": code, "deviceId": dev.id, "deviceName": dev.name])

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError.networkError
        }

        switch httpResponse.statusCode {
        case 200:
            let result = try JSONDecoder().decode(PairResponse.self, from: data)
            self.token = result.token
            UserDefaults.standard.set(result.token, forKey: "bridge_token")
            return result.token

        case 401:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if body?.error.contains("expired") == true {
                throw BridgeError.expired
            }
            throw BridgeError.invalidCode

        case 429:
            throw BridgeError.rateLimited

        default:
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw BridgeError.serverError(body?.error ?? "Unknown error (HTTP \(httpResponse.statusCode))")
        }
    }

    // MARK: - Commands

    /// Sends a text command to a session's PTY, or directly to a cmux terminal.
    /// `submit` appends Enter (default). Pass `submit: false` to type without
    /// submitting — e.g. a single digit to pick a row in an interactive picker.
    func sendCommand(text: String, sessionId: String? = nil, terminalId: String? = nil, submit: Bool = true) async throws {
        var body: [String: Any] = ["command": text, "submit": submit]
        if let sid = sessionId { body["sessionId"] = sid }
        if let tid = terminalId { body["terminalId"] = tid }
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Sends a named special key (up/down/left/right/enter/escape/tab/backspace)
    /// to a cmux terminal — used to drive interactive TUI pickers like codex's
    /// `/model` popup from the phone.
    func sendKey(terminalId: String, key: String) async throws {
        try await authenticatedPostRaw(path: "command", body: ["key": key, "terminalId": terminalId])
    }

    /// Fetches the live cmux workspace/terminal tree (raw JSON data).
    func fetchCmuxTree() async throws -> Data {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("cmux/tree")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.networkError
        }
        return data
    }

    /// Reads the plain-text screen of one cmux terminal, plus its hash (used to
    /// guard approval responses against the screen changing mid-flight).
    func fetchCmuxScreen(terminalId: String) async throws -> CmuxScreen {
        guard let baseURL, let token else { throw BridgeError.networkError }
        var comps = URLComponents(url: baseURL.appendingPathComponent("cmux/screen"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "id", value: terminalId)]
        guard let url = comps?.url else { throw BridgeError.networkError }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.networkError
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return CmuxScreen(text: (json?["text"] as? String) ?? "", hash: json?["hash"] as? String)
    }

    /// Send input to a cmux terminal, guarded by the screen hash the phone last
    /// rendered. The bridge refuses (409) if the screen changed since — so an
    /// approval "yes"/"no" can't land on a different prompt.
    func sendCmuxGuarded(terminalId: String, text: String, expectedScreenHash: String?, submit: Bool = true) async -> CmuxSendResult {
        guard let baseURL, let token else { return .failed("not paired") }
        let url = baseURL.appendingPathComponent("command")
        var body: [String: Any] = ["command": text, "terminalId": terminalId, "submit": submit]
        if let h = expectedScreenHash { body["expectedScreenHash"] = h }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await performRequest(request)
            guard let http = response as? HTTPURLResponse else { return .failed("no response") }
            if (200..<300).contains(http.statusCode) { return .sent }
            if http.statusCode == 409 {
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return .screenChanged(text: (json?["currentScreen"] as? String) ?? "",
                                      hash: json?["currentHash"] as? String)
            }
            return .failed("HTTP \(http.statusCode)")
        } catch {
            return .failed("network")
        }
    }

    /// Spawns a new agent session.
    func spawnSession(agent: String, cwd: String? = nil) async throws -> String {
        var body: [String: Any] = ["spawn": agent]
        if let cwd { body["cwd"] = cwd }
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("command")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BridgeError.serverError("Failed to spawn session")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["sessionId"] as? String ?? ""
    }

    /// Attaches the live-terminal pin (terminalId + expectedScreenHash) to an
    /// approval body so the bridge can refuse (409) if the screen changed.
    private func pin(_ body: inout [String: Any], terminalId: String?, expectedScreenHash: String?) {
        if let tid = terminalId { body["terminalId"] = tid }
        if let h = expectedScreenHash { body["expectedScreenHash"] = h }
    }

    /// Responds to an approval request.
    func respondToApproval(requestId: String, allow: Bool, terminalId: String? = nil, expectedScreenHash: String? = nil) async throws {
        var decision: [String: Any] = [
            "behavior": allow ? "allow" : "deny"
        ]
        if !allow {
            decision["message"] = "Denied from Agent iPhone app"
        }
        var body: [String: Any] = [
            "permissionId": requestId,
            "decision": decision
        ]
        pin(&body, terminalId: terminalId, expectedScreenHash: expectedScreenHash)
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Responds to an approval with a selected option (for dynamic options / AskUserQuestion).
    func respondToApprovalWithOption(requestId: String, optionLabel: String, index: Int, terminalId: String? = nil, expectedScreenHash: String? = nil) async throws {
        var body: [String: Any] = [
            "permissionId": requestId,
            "decision": ["behavior": "allow"],
            "selectedOption": optionLabel,
            "optionIndex": index
        ]
        pin(&body, terminalId: terminalId, expectedScreenHash: expectedScreenHash)
        try await authenticatedPostRaw(path: "command", body: body)
    }

    /// Responds with "allow" + adds a permission rule so it doesn't ask again this session.
    func respondToApprovalAllowAll(requestId: String, terminalId: String? = nil, expectedScreenHash: String? = nil) async throws {
        let decision: [String: Any] = [
            "behavior": "allow"
        ]
        var body: [String: Any] = [
            "permissionId": requestId,
            "decision": decision,
            "allowAll": true
        ]
        pin(&body, terminalId: terminalId, expectedScreenHash: expectedScreenHash)
        try await authenticatedPostRaw(path: "command", body: body)
    }

    // MARK: - Status

    /// Toggle supervise mode (broad PreToolUse approval) on the bridge.
    func setSupervise(on: Bool) async throws {
        try await authenticatedPostRaw(path: "supervise", body: ["on": on])
    }

    /// Fetches the current bridge status. /status now requires auth (it exposes
    /// session cwds), so send the bearer token.
    func fetchStatus() async throws -> BridgeStatus {
        guard let baseURL else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent("status")
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await performRequest(request)
        return try JSONDecoder().decode(BridgeStatus.self, from: data)
    }

    // MARK: - SSE URL

    /// Returns the URL for the SSE events endpoint, including auth.
    func eventsURL() -> URL? {
        guard let baseURL, let token else { return nil }
        var components = URLComponents(url: baseURL.appendingPathComponent("events"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url
    }

    // MARK: - Private helpers

    private func authenticatedPost(path: String, body: [String: String]) async throws {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError.serverError("Request failed")
        }
    }

    private func authenticatedPostRaw(path: String, body: [String: Any]) async throws {
        guard let baseURL, let token else { throw BridgeError.networkError }
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await performRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BridgeError.networkError
        }
        // 409 = the bridge refused because the terminal screen changed since the
        // user was shown the approval (expectedScreenHash mismatch).
        if httpResponse.statusCode == 409 { throw BridgeError.screenChanged }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BridgeError.serverError("Request failed (HTTP \(httpResponse.statusCode))")
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            // Preserve the real reason in the device log (e.g. ATS -1022) before
            // collapsing to the coarse BridgeError the UI consumes.
            if let u = error as? URLError {
                print("[BridgeClient] request failed: code=\(u.errorCode) \(u.localizedDescription) url=\(request.url?.absoluteString ?? "?")")
            } else {
                print("[BridgeClient] request failed: \(error)")
            }
            throw BridgeError.networkError
        }
    }

    // MARK: - Response types

    private struct PairResponse: Decodable {
        let token: String
        let sessionId: String?
        let bridgeId: String?
        let availableAgents: [String]?
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    struct BridgeStatus: Decodable {
        let state: String
        let sessionId: String?
        let bridgeId: String?
        let hasPty: Bool
        let activeAgent: String?
        let availableAgents: [String]?
        let sessions: [BridgeSessionInfo]?
        let sseClients: Int
        let pendingPermissions: Int
        let eventBufferSize: Int
        let supervise: Bool?
    }

    struct BridgeSessionInfo: Decodable {
        let id: String
        let agent: String
        let cwd: String
        let folderName: String
        let state: String
    }
}
