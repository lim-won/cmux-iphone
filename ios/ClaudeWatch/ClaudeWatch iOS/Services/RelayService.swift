import Foundation
import Combine
import UIKit

/// Coordinates communication between the bridge server, SSE event stream,
/// and the Apple Watch via WCSession.
///
/// Acts as the central hub: bridge events are received via SSE/polling,
/// parsed, and forwarded to the watch. Commands from the watch are
/// received via WCSession and forwarded to the bridge via HTTP.
@MainActor
final class RelayService: ObservableObject {

    // MARK: - Singleton

    static let shared = RelayService()

    // MARK: - Published state

    @Published private(set) var isPaired: Bool = false
    /// True while the user is pairing an ADDITIONAL Mac (shows PairingView over the list).
    @Published var isAddingMac: Bool = false
    @Published private(set) var machineName: String?
    @Published private(set) var modelName: String?
    @Published private(set) var workingDirectory: String?
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var recentTerminalLines: [TerminalLine] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var lastConnected: Date?
    @Published private(set) var isThinking: Bool = false

    // Multi-session
    @Published private(set) var sessions: [AgentSession] = []

    // Permission prompt state (uses shared ApprovalRequest model)
    // `pendingApproval` is the head of the queue, kept for existing per-session UI.
    @Published var pendingApproval: ApprovalRequest? = nil
    /// Global approval queue across all sessions of the active Mac. Drives the
    /// app-wide badge + queue sheet.
    @Published private(set) var approvalQueue: [ApprovalRequest] = []
    var pendingApprovalCount: Int { approvalQueue.count }
    /// permissionIds we've already answered/cleared — makes responses single-use
    /// and lets us ignore the bridge's reconnect re-sends of resolved approvals.
    private var resolvedPermissionIds: Set<String> = []

    // cmux mirror — populated when the connected Mac runs cmux.
    @Published private(set) var cmuxAvailable: Bool = false
    @Published private(set) var cmuxWorkspaces: [CmuxWorkspace] = []
    /// Bumped on every cmux event so terminal views refetch their screen live.
    @Published private(set) var cmuxScreenTick: Int = 0

    /// Supervise mode — when ON, the bridge routes mutating tools through phone
    /// approval (all permission modes). Mirrors the bridge's state.
    @Published var superviseMode: Bool = false

    // MARK: - Private

    private let bridgeClient = BridgeClient()
    private let sseClient = SSEClient()
    private let discovery = BonjourDiscovery()
    private let notificationService = NotificationService()
    private let sessionManager = WatchSessionManager.shared

    private let terminalBuffer = OutputRingBuffer<TerminalLine>(capacity: 50)
    private var terminalBatchTimer: Timer?
    private var pendingTerminalLines: [TerminalLine] = []

    private var elapsedTimer: Timer?
    private var sessionStartDate: Date?
    private var sseRetryTimer: Timer?   // periodic SSE re-attempt while degraded to polling

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        isPaired = bridgeClient.isPaired
        setupWatchMessageHandler()
        setupSSEEventHandler()

        if isPaired {
            Task { await reconnect() }
        }
    }

    // MARK: - Pairing

    /// Discovers the bridge on LAN and pairs with the given code.
    func pair(code: String) async throws {
        print("[RelayService] Starting pair with code: \(code)")

        // Discover bridge via Bonjour (or localhost fallback)
        let service: BonjourDiscovery.DiscoveredService
        do {
            service = try await discovery.discover()
            print("[RelayService] Discovered bridge at \(service.host):\(service.port)")
        } catch {
            print("[RelayService] Discovery failed: \(error)")
            throw error
        }

        // Configure the HTTP client
        bridgeClient.configure(host: service.host, port: service.port)

        // Attempt pairing
        do {
            try await bridgeClient.pair(code: code)
            print("[RelayService] Pairing successful!")
        } catch {
            print("[RelayService] Pairing failed: \(error)")
            throw error
        }

        // Success
        machineName = service.machineName
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        if let token = bridgeClient.token {
            ConnectionStore.shared.upsert(
                name: service.machineName ?? service.host,
                host: service.host, port: Int(service.port), token: token
            )
        }
        isAddingMac = false

        UserDefaults.standard.set(service.host, forKey: "bridge_host")
        UserDefaults.standard.set(Int(service.port), forKey: "bridge_port")
        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

        print("[RelayService] isPaired = true, starting event stream")

        // Start SSE connection
        startEventStream()
        startElapsedTimer()

        // Notify watch of connection
        updateWatchState()
    }

    /// Pairs using a manual IP address (fallback when Bonjour fails on real devices).
    func pairWithIP(_ ip: String, code: String) async throws {
        print("[RelayService] Manual IP pair: \(ip), code: \(code)")

        let service = try await discovery.discoverAtIP(ip)
        bridgeClient.configure(host: service.host, port: service.port)

        try await bridgeClient.pair(code: code)

        machineName = service.machineName
        lastConnected = Date()
        isPaired = true
        connectionState = .connected

        if let token = bridgeClient.token {
            ConnectionStore.shared.upsert(
                name: service.machineName ?? service.host,
                host: service.host, port: Int(service.port), token: token
            )
        }
        isAddingMac = false

        UserDefaults.standard.set(service.host, forKey: "bridge_host")
        UserDefaults.standard.set(Int(service.port), forKey: "bridge_port")
        UserDefaults.standard.set(service.machineName, forKey: "paired_machine_name")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")

        startEventStream()
        startElapsedTimer()
        updateWatchState()
    }

    /// Removes pairing and disconnects.
    func unpair() {
        sseClient.disconnect()
        stopSSERetry()
        bridgeClient.clearCredentials()
        stopElapsedTimer()
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil

        isPaired = false
        machineName = nil
        modelName = nil
        workingDirectory = nil
        resetPerMacState()
        connectionState = .disconnected

        UserDefaults.standard.removeObject(forKey: "paired_machine_name")
        UserDefaults.standard.removeObject(forKey: "last_connected")

        // Notify watch
        let state = SessionState.disconnected
        sessionManager.updateApplicationContext(with: state)
    }

    // MARK: - Multi-Mac switching

    /// Switch to an already-paired Mac with one tap (no re-pairing).
    func switchTo(_ conn: SavedConnection) {
        sseClient.disconnect()
        stopSSERetry()
        stopElapsedTimer()
        sessionStartDate = nil
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil
        pendingTerminalLines = []

        resetPerMacState()

        bridgeClient.applyActive(host: conn.host, port: UInt16(conn.port), token: conn.token)
        ConnectionStore.shared.setActive(conn.id)

        machineName = conn.name
        isPaired = true
        isAddingMac = false
        connectionState = .connecting

        UserDefaults.standard.set(conn.name, forKey: "paired_machine_name")

        startEventStream()
        startElapsedTimer()
        updateWatchState()
    }

    /// Reflect a rename of the active connection into the live UI label.
    func refreshActiveName() {
        if let active = ConnectionStore.shared.active {
            machineName = active.name
            UserDefaults.standard.set(active.name, forKey: "paired_machine_name")
            updateWatchState()
        }
    }

    // MARK: - cmux mirror

    /// Fetch the live cmux workspace/terminal tree.
    func refreshCmuxTree() {
        Task { @MainActor in
            do {
                let data = try await bridgeClient.fetchCmuxTree()
                let decoded = try JSONDecoder().decode(CmuxTreeResponse.self, from: data)
                cmuxAvailable = decoded.available
                cmuxWorkspaces = decoded.workspaces
            } catch {
                // keep previous state on transient failures
            }
        }
    }

    /// Read one cmux terminal's plain-text screen (with hash for safe responses).
    func cmuxScreen(_ terminalId: String) async -> CmuxScreen? {
        try? await bridgeClient.fetchCmuxScreen(terminalId: terminalId)
    }

    /// Send a prompt straight to a cmux terminal (types + Enter). Unguarded —
    /// for normal prompts where the screen is expected to keep changing.
    func sendCmux(terminalId: String, text: String) {
        Task { try? await bridgeClient.sendCommand(text: text, terminalId: terminalId) }
    }

    /// Awaitable cmux text send with explicit submit control — used by the codex
    /// model/effort driver, which types a slash command (submit) then picks rows
    /// with single digits (no submit). Unguarded by design (it drives the screen).
    func sendCmuxText(terminalId: String, text: String, submit: Bool) async {
        try? await bridgeClient.sendCommand(text: text, terminalId: terminalId, submit: submit)
    }

    /// Send a named special key (up/down/enter/escape/…) to a cmux terminal —
    /// drives interactive TUI pickers like codex's `/model` popup.
    func sendCmuxKey(terminalId: String, key: String) async {
        try? await bridgeClient.sendKey(terminalId: terminalId, key: key)
    }

    /// Send an approval response guarded by the screen hash the user was viewing.
    /// Returns .screenChanged if the bridge rejected because the screen moved.
    func sendCmuxGuarded(terminalId: String, text: String, expectedScreenHash: String?, submit: Bool = true) async -> CmuxSendResult {
        await bridgeClient.sendCmuxGuarded(terminalId: terminalId, text: text, expectedScreenHash: expectedScreenHash, submit: submit)
    }

    // MARK: - Supervise mode

    /// Toggle broad phone-approval (PreToolUse) on the bridge. Optimistic.
    func setSupervise(_ on: Bool) {
        superviseMode = on
        Task {
            do { try await bridgeClient.setSupervise(on: on) }
            catch { await MainActor.run { self.refreshSupervise() } } // resync on failure
        }
    }

    /// Sync the toggle with the bridge's actual state.
    func refreshSupervise() {
        Task { @MainActor in
            if let st = try? await bridgeClient.fetchStatus() {
                superviseMode = st.supervise ?? false
            }
        }
    }

    /// Start pairing an additional Mac (PairingView is shown over the list).
    func beginAddMac() { isAddingMac = true }
    func cancelAddMac() { isAddingMac = false }

    /// Forget the active Mac; switch to another saved Mac if one exists.
    func forgetActive() {
        let store = ConnectionStore.shared
        if let id = store.activeID { store.remove(id) }

        sseClient.disconnect()
        stopSSERetry()

        if let next = store.active {
            switchTo(next)
            return
        }

        // No Macs left — fall back to the pairing screen.
        bridgeClient.clearCredentials()
        stopElapsedTimer()
        terminalBatchTimer?.invalidate()
        terminalBatchTimer = nil

        isPaired = false
        isAddingMac = false
        machineName = nil
        resetPerMacState()
        connectionState = .disconnected

        sessionManager.updateApplicationContext(with: SessionState.disconnected)
    }

    /// Reset all per-Mac view state — sessions, terminal, approvals, AND the cmux
    /// mirror (cmuxAvailable/cmuxWorkspaces/cmuxScreenTick) — so switching or
    /// forgetting a Mac never leaves the previous Mac's workspaces visible or
    /// tappable. Field-by-field reset previously drifted; centralize it here.
    private func resetPerMacState() {
        sessions = []
        recentTerminalLines = []
        terminalBuffer.clear()
        pendingApproval = nil
        approvalQueue = []
        resolvedPermissionIds = []
        isThinking = false
        elapsedSeconds = 0
        cmuxAvailable = false
        cmuxWorkspaces = []
        cmuxScreenTick = 0
    }

    // MARK: - Reconnection

    private func reconnect() async {
        guard bridgeClient.isPaired else { return }

        machineName = UserDefaults.standard.string(forKey: "paired_machine_name")
        if let ts = UserDefaults.standard.object(forKey: "last_connected") as? TimeInterval {
            lastConnected = Date(timeIntervalSince1970: ts)
        }

        connectionState = .connecting
        startEventStream()
        startElapsedTimer()
    }

    // MARK: - SSE

    private func startEventStream() {
        guard let baseURL = bridgeClient.baseURL, let token = bridgeClient.token else { return }
        sseClient.connect(baseURL: baseURL, token: token)
    }

    private func setupSSEEventHandler() {
        sseClient.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBridgeEvent(event)
            }
        }

        sseClient.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connected:
                    self?.connectionState = .connected
                    self?.stopSSERetry()
                    self?.lastConnected = Date()
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "last_connected")
                    self?.updateWatchState()
                case .connecting:
                    self?.connectionState = .connecting
                case .disconnected:
                    self?.connectionState = .disconnected
                    self?.stopSSERetry()
                    self?.updateWatchState()
                case .polling:
                    // Realtime (SSE) is lost — /status polling has no approvals or
                    // terminal output. Surface as DEGRADED (not connected) and keep
                    // trying to restore SSE so missed approvals replay on reconnect.
                    self?.connectionState = .degraded
                    self?.updateWatchState()
                    self?.scheduleSSERetry()
                }
            }
        }
    }

    // MARK: - SSE recovery (degraded -> retry)

    private func scheduleSSERetry() {
        guard sseRetryTimer == nil else { return }
        sseRetryTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sseClient.retrySSE() }
        }
    }

    private func stopSSERetry() {
        sseRetryTimer?.invalidate()
        sseRetryTimer = nil
    }

    private func handleBridgeEvent(_ event: SSEClient.SSEEvent) {
        guard let eventType = event.event else { return }
        let data = event.data

        switch eventType {
        case "pty-output":
            handlePtyOutput(data)

        case "permission-request":
            handlePermissionRequest(data)

        case "permission-cleared":
            handlePermissionCleared(data)

        case "session":
            handleSessionEvent(data)

        case "tool-output":
            handleToolOutput(data)

        case "task-complete":
            handleTaskComplete(data)

        case "error":
            handleError(data)

        case "stop":
            handleStop(data)

        case "cmux-event":
            refreshCmuxTree()
            cmuxScreenTick &+= 1

        case "poll-status":
            // Polling fallback -- just keep alive
            break

        default:
            break
        }
    }

    // MARK: - Event handlers

    private func handlePtyOutput(_ data: String) {
        guard let json = parseJSON(data),
              let text = json["text"] as? String else { return }
        let sessionId = json["sessionId"] as? String

        // Strip ANSI escape codes for display
        let cleaned = text.replacingOccurrences(
            of: "\\x1B\\[[0-9;]*[a-zA-Z]",
            with: "",
            options: .regularExpression
        )

        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let line = TerminalLine(text: cleaned, type: .output, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Batch terminal updates to the watch (1-second window)
        pendingTerminalLines.append(line)
        scheduleBatchSend()
    }

    private func handlePermissionRequest(_ data: String) {
        guard let json = parseJSON(data) else { return }

        let permissionId = json["permissionId"] as? String ?? UUID().uuidString
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let sessionId = json["sessionId"] as? String

        var question: String? = nil
        var desc = toolName
        var options: [ApprovalRequest.OptionItem] = []

        // Parse questions/options (Codex format with questions array)
        if let questions = toolInput["questions"] as? [[String: Any]],
           let firstQ = questions.first {
            question = firstQ["question"] as? String
            desc = toolInput["command"] as? String
                ?? firstQ["header"] as? String
                ?? toolName
            if let opts = firstQ["options"] as? [[String: Any]] {
                options = opts.map { opt in
                    ApprovalRequest.OptionItem(
                        label: opt["label"] as? String ?? "",
                        description: opt["description"] as? String
                    )
                }
            }
        } else if let path = toolInput["file_path"] as? String {
            let filename = (path as NSString).lastPathComponent
            desc = "\(toolName) \(filename)"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else if let cmd = toolInput["command"] as? String {
            desc = "Run: \(String(cmd.prefix(100)))"
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "Yes, allow all"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        } else {
            options = [
                ApprovalRequest.OptionItem(label: "Yes"),
                ApprovalRequest.OptionItem(label: "No"),
            ]
        }

        print("[RelayService] Permission requested: \(toolName) — \(desc)")

        let reason = toolInput["reason"] as? String ?? (json["reason"] as? String)
        let session = sessionId.flatMap { sid in sessions.first(where: { $0.id == sid }) }
        // Live-terminal pin (codex/cmux approvals): the bridge snapshots the
        // terminal + its screen hash so the answer can't land on a wrong/changed screen.
        let terminalId = json["terminalId"] as? String
        let expectedHash = json["screenHash"] as? String ?? (json["expectedScreenHash"] as? String)
        let approval = ApprovalRequest(
            permissionId: permissionId,
            toolName: toolName,
            actionSummary: desc,
            question: question,
            options: options,
            sessionId: sessionId,
            macName: machineName,
            cwd: session?.cwd,
            agent: session?.agent.rawValue ?? (json["source"] as? String),
            reason: reason,
            terminalId: terminalId,
            expectedScreenHash: expectedHash
        )

        // Ignore re-sends of an approval we've already answered/cleared.
        if let pid = approval.permissionId, resolvedPermissionIds.contains(pid) { return }

        // De-dupe: the bridge re-sends pending approvals on every SSE reconnect.
        if let idx = approvalQueue.firstIndex(where: { $0.dedupeKey == approval.dedupeKey }) {
            approvalQueue[idx] = approval               // refresh in place
            pendingApproval = approvalQueue.first
            if let sid = sessionId, let sIdx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[sIdx].pendingApproval = approval
                sessions[sIdx].activity = .waitingApproval
            }
            return                                       // no new haptic / notification
        }

        approvalQueue.append(approval)
        pendingApproval = approvalQueue.first

        // Track on specific session
        if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].pendingApproval = approval
            sessions[idx].activity = .waitingApproval
        }

        // Haptic feedback
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()

        // Add to terminal
        let line = TerminalLine(text: "⚠ Permission: \(desc)", type: .system, sessionId: sessionId)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        appendToSession(line, sessionId: sessionId)

        // Forward to watch
        let watchRequest = ApprovalRequest(toolName: toolName, actionSummary: desc, question: question, options: options)
        let message = WatchMessage.approvalRequestMessage(watchRequest)
        sessionManager.send(message)

        // Notification if backgrounded
        notificationService.postApprovalNeeded(toolName: toolName, summary: desc)
    }

    // MARK: - Permission response

    /// Respond to a SPECIFIC approval with a selected option (queue-aware).
    /// Single-use: a permissionId can only be answered once, even if the card
    /// is shown in both the queue sheet and a session detail.
    func respond(to approval: ApprovalRequest, optionLabel: String, index: Int) {
        let permissionId = approval.permissionId ?? ""
        // Transactional: don't double-submit, and don't re-answer a resolved id.
        // The card is removed ONLY after the bridge confirms (HTTP 2xx).
        if currentStatus(of: approval) == .submitting { return }
        if !permissionId.isEmpty, resolvedPermissionIds.contains(permissionId) { return }

        let isLast = index == approval.options.count - 1
        UIImpactFeedbackGenerator(style: isLast ? .heavy : .medium).impactOccurred()
        setStatus(.submitting, for: approval)

        let tid = approval.terminalId
        let hash = approval.expectedScreenHash
        Task { @MainActor in
            do {
                if approval.question != nil {
                    // AskUserQuestion: send the option label (index -1 == freeform text)
                    try await bridgeClient.respondToApprovalWithOption(
                        requestId: permissionId, optionLabel: optionLabel, index: index,
                        terminalId: tid, expectedScreenHash: hash)
                } else if optionLabel.lowercased().contains("allow all") || optionLabel.lowercased().contains("don't ask") {
                    try await bridgeClient.respondToApprovalAllowAll(
                        requestId: permissionId, terminalId: tid, expectedScreenHash: hash)
                } else {
                    try await bridgeClient.respondToApproval(
                        requestId: permissionId, allow: !isLast, terminalId: tid, expectedScreenHash: hash)
                }
                // Success — only NOW mark resolved + remove the card.
                if !permissionId.isEmpty { resolvedPermissionIds.insert(permissionId) }
                let line = TerminalLine(text: "→ \(optionLabel)", type: isLast ? .error : .output)
                terminalBuffer.append(line)
                recentTerminalLines = terminalBuffer.getLast(15)
                clearPendingApproval(for: approval)
            } catch {
                // Failure — keep the card, surface the error, allow retry.
                setStatus(.failed, for: approval, error: friendlyError(error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                let line = TerminalLine(text: "✗ 승인 전송 실패 — 다시 시도하세요", type: .error)
                terminalBuffer.append(line)
                recentTerminalLines = terminalBuffer.getLast(15)
            }
        }
    }

    /// Live status of an approval (the `approval` argument is a value snapshot).
    private func currentStatus(of approval: ApprovalRequest) -> ApprovalRequest.ApprovalStatus {
        approvalQueue.first(where: { $0.dedupeKey == approval.dedupeKey })?.status ?? approval.status
    }

    /// Update an approval's status (+optional error) in BOTH the queue and the
    /// owning session — ApprovalRequest is a value type, so we patch every copy.
    private func setStatus(_ status: ApprovalRequest.ApprovalStatus, for approval: ApprovalRequest, error: String? = nil) {
        if let i = approvalQueue.firstIndex(where: { $0.dedupeKey == approval.dedupeKey }) {
            approvalQueue[i].status = status
            approvalQueue[i].lastError = error
        }
        pendingApproval = approvalQueue.first
        for i in sessions.indices where sessions[i].pendingApproval?.permissionId == approval.permissionId {
            sessions[i].pendingApproval?.status = status
            sessions[i].pendingApproval?.lastError = error
        }
    }

    private func friendlyError(_ error: Error) -> String {
        if let be = error as? BridgeClient.BridgeError {
            switch be {
            case .screenChanged: return "화면이 바뀌었습니다 — 다시 확인 후 시도하세요"
            case .networkError:  return "브리지에 연결할 수 없습니다"
            case .rateLimited:   return "잠시 후 다시 시도하세요"
            default:             return be.errorDescription ?? "전송 실패"
            }
        }
        return "전송 실패"
    }

    /// Back-compat: respond to the current head of the queue.
    func respondToApprovalWithOption(_ optionLabel: String, index: Int) {
        guard let approval = pendingApproval else { return }
        respond(to: approval, optionLabel: optionLabel, index: index)
    }

    /// Explicit "allow for this session" — adds a permission rule so it won't ask again.
    func respondAllowSession(_ approval: ApprovalRequest) {
        let permissionId = approval.permissionId ?? ""
        if currentStatus(of: approval) == .submitting { return }
        if !permissionId.isEmpty, resolvedPermissionIds.contains(permissionId) { return }

        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        setStatus(.submitting, for: approval)

        let tid = approval.terminalId
        let hash = approval.expectedScreenHash
        Task { @MainActor in
            do {
                try await bridgeClient.respondToApprovalAllowAll(
                    requestId: permissionId, terminalId: tid, expectedScreenHash: hash)
                if !permissionId.isEmpty { resolvedPermissionIds.insert(permissionId) }
                clearPendingApproval(for: approval)
            } catch {
                setStatus(.failed, for: approval, error: friendlyError(error))
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Send command

    /// Sends a text command to the bridge (iOS equivalent of watchOS voice input).
    func sendCommand(text: String, sessionId: String? = nil) {
        let sid = sessionId ?? sessions.first(where: { $0.activity == .running })?.id

        // Show in terminal
        let cmdLine = TerminalLine(text: "> \(text)", type: .command, sessionId: sid)
        terminalBuffer.append(cmdLine)
        appendToSession(cmdLine, sessionId: sid)
        recentTerminalLines = terminalBuffer.getLast(15)

        isThinking = true

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        Task {
            try? await bridgeClient.sendCommand(text: text + "\n", sessionId: sid)
        }
    }

    // MARK: - Clear terminal

    func clearTerminal(sessionId: String? = nil) {
        if let sid = sessionId,
           let idx = sessions.firstIndex(where: { $0.id == sid }) {
            sessions[idx].terminalLines.removeAll()
        }
        terminalBuffer.clear()
        recentTerminalLines = []
        isThinking = false
    }

    // MARK: - Helpers (approval)

    private func clearPendingApproval(for approval: ApprovalRequest) {
        approvalQueue.removeAll { $0.dedupeKey == approval.dedupeKey }
        pendingApproval = approvalQueue.first
        for idx in sessions.indices {
            if sessions[idx].pendingApproval?.permissionId == approval.permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
    }

    /// Server told us an approval was resolved/timed-out elsewhere (or on another
    /// device) — drop it from the queue + sessions so the card disappears.
    private func handlePermissionCleared(_ data: String) {
        guard let json = parseJSON(data),
              let permissionId = json["permissionId"] as? String else { return }
        resolvedPermissionIds.insert(permissionId) // ignore any late re-send
        approvalQueue.removeAll { $0.permissionId == permissionId }
        pendingApproval = approvalQueue.first
        for idx in sessions.indices {
            if sessions[idx].pendingApproval?.permissionId == permissionId {
                sessions[idx].pendingApproval = nil
                if sessions[idx].activity == .waitingApproval {
                    sessions[idx].activity = .running
                }
            }
        }
    }

    private func appendToSession(_ line: TerminalLine, sessionId: String?) {
        guard let sid = sessionId,
              let idx = sessions.firstIndex(where: { $0.id == sid }) else { return }
        sessions[idx].terminalLines.append(line)
        if sessions[idx].terminalLines.count > 500 {
            sessions[idx].terminalLines.removeFirst(sessions[idx].terminalLines.count - 500)
        }
    }

    private func handleSessionEvent(_ data: String) {
        guard let json = parseJSON(data),
              let state = json["state"] as? String else { return }

        let sessionId = json["sessionId"] as? String
        let agent = json["agent"] as? String
        let cwd = json["cwd"] as? String ?? ""
        let folderName = json["folderName"] as? String ?? ""

        switch state {
        case "running":
            sessionStartDate = Date()
            if let sid = sessionId {
                if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                    sessions[idx].activity = .running
                } else {
                    let agentType = AgentType(rawValue: agent ?? "claude") ?? .claude
                    sessions.append(AgentSession(
                        id: sid, agent: agentType, cwd: cwd,
                        folderName: folderName, activity: .running
                    ))
                }
            }
        case "ended":
            isThinking = false
            stopElapsedTimer()
            notificationService.postTaskComplete()
            if let sid = sessionId, let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx].activity = .ended
            }
        case "connected":
            connectionState = .connected
        default:
            break
        }

        updateWatchState()
    }

    private func handleToolOutput(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let toolName = json["tool_name"] as? String ?? "tool"
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]
        let toolOutput = json["tool_output"] as? String
        let sessionId = json["sessionId"] as? String
        let source = json["source"] as? String ?? "claude"
        let prefix = source == "codex" ? "[codex] " : ""

        // Format like a real terminal: show what Claude did and the result
        var lines: [TerminalLine] = []

        switch toolName {
        case "Bash":
            let cmd = toolInput["command"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)$ \(cmd)", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let outputLines = output.components(separatedBy: "\n")
                for line in outputLines.prefix(10) {
                    let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        lines.append(TerminalLine(text: cleaned, type: .output, sessionId: sessionId))
                    }
                }
                if outputLines.count > 10 {
                    lines.append(TerminalLine(text: "  ... (\(outputLines.count - 10) more lines)", type: .system, sessionId: sessionId))
                }
            }

        case "Read":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Read \(filename)", type: .system, sessionId: sessionId))

        case "Write":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            lines.append(TerminalLine(text: "\(prefix)Write \(filename)", type: .system, sessionId: sessionId))

        case "Edit":
            let path = toolInput["file_path"] as? String ?? ""
            let filename = (path as NSString).lastPathComponent
            let oldStr = toolInput["old_string"] as? String ?? ""
            let newStr = toolInput["new_string"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)Edit \(filename)", type: .system, sessionId: sessionId))
            if !oldStr.isEmpty {
                let preview = oldStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  - \(String(preview.prefix(60)))", type: .error, sessionId: sessionId))
            }
            if !newStr.isEmpty {
                let preview = newStr.components(separatedBy: "\n").first ?? ""
                lines.append(TerminalLine(text: "  + \(String(preview.prefix(60)))", type: .output, sessionId: sessionId))
            }

        case "Grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)grep \"\(pattern)\"", type: .command, sessionId: sessionId))
            if let output = toolOutput, !output.isEmpty {
                let resultLines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                lines.append(TerminalLine(text: "  \(resultLines.count) matches", type: .system, sessionId: sessionId))
            }

        case "Glob":
            let pattern = toolInput["pattern"] as? String ?? ""
            lines.append(TerminalLine(text: "\(prefix)find \"\(pattern)\"", type: .command, sessionId: sessionId))

        case "CodexMessage":
            if let output = toolOutput {
                lines.append(TerminalLine(text: "\(prefix)\(String(output.prefix(100)))", type: .output, sessionId: sessionId))
            }

        default:
            lines.append(TerminalLine(text: "\(prefix)[\(toolName)]", type: .system, sessionId: sessionId))
            if let output = toolOutput {
                let preview = String(output.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preview.isEmpty {
                    lines.append(TerminalLine(text: preview, type: .output, sessionId: sessionId))
                }
            }
        }

        for line in lines {
            terminalBuffer.append(line)
            pendingTerminalLines.append(line)
            appendToSession(line, sessionId: sessionId)
        }

        // Mark as thinking (cursor will be shown in the view)
        isThinking = true

        recentTerminalLines = terminalBuffer.getLast(10)
        scheduleBatchSend()
    }

    private func handleTaskComplete(_ data: String) {
        isThinking = false
        let line = TerminalLine(text: "Task completed", type: .system)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
        notificationService.postTaskComplete()
        updateWatchState()
    }

    private func handleError(_ data: String) {
        guard let json = parseJSON(data) else { return }
        let errorMsg = json["error"] as? String ?? "Unknown error"
        let line = TerminalLine(text: errorMsg, type: .error)
        terminalBuffer.append(line)
        recentTerminalLines = terminalBuffer.getLast(15)
    }

    private func handleStop(_ data: String) {
        isThinking = false
        let json = parseJSON(data)
        let sessionId = json?["sessionId"] as? String

        // Render Claude's final answer. The bridge reads it from the transcript
        // on Stop and forwards it as `assistantText` — this is the only place the
        // reply text appears (tool actions arrive separately via tool-output).
        if let answer = json?["assistantText"] as? String,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for raw in answer.components(separatedBy: "\n") {
                let line = TerminalLine(text: raw, type: .output, sessionId: sessionId)
                terminalBuffer.append(line)
                appendToSession(line, sessionId: sessionId)
                pendingTerminalLines.append(line)
            }
        }

        let stopLine = TerminalLine(text: "Session stopped", type: .system, sessionId: sessionId)
        terminalBuffer.append(stopLine)
        appendToSession(stopLine, sessionId: sessionId)
        recentTerminalLines = terminalBuffer.getLast(15)
        scheduleBatchSend()
        updateWatchState()
    }

    // MARK: - Watch communication

    private func setupWatchMessageHandler() {
        sessionManager.onMessageReceived = { [weak self] message in
            Task { @MainActor in
                self?.handleWatchMessage(message)
            }
        }
    }

    private func handleWatchMessage(_ message: WatchMessage) {
        switch message {
        case .voiceCommand(let cmd):
            // Forward voice command to bridge as PTY input
            Task {
                try? await bridgeClient.sendCommand(text: cmd.transcribedText + "\n")
            }

        case .approvalResponse(let response):
            // Forward approval response to bridge
            let key = "pending_permission_\(response.requestId.uuidString)"
            if let permissionId = UserDefaults.standard.string(forKey: key) {
                Task {
                    try? await bridgeClient.respondToApproval(
                        requestId: permissionId,
                        allow: response.approved
                    )
                }
                UserDefaults.standard.removeObject(forKey: key)
            }

        default:
            break
        }
    }

    private func updateWatchState() {
        let state = SessionState(
            connection: connectionState,
            activity: currentActivity,
            machineName: machineName,
            modelName: modelName,
            workingDirectory: workingDirectory,
            elapsedSeconds: elapsedSeconds,
            filesChanged: 0,
            linesAdded: 0,
            transportMode: .lan
        )

        sessionManager.updateApplicationContext(with: state)
    }

    private var currentActivity: SessionActivity {
        switch connectionState {
        case .connected: return .running
        case .degraded: return .running   // still alive, just no realtime stream
        case .connecting: return .idle
        case .disconnected: return .ended
        case .iPhoneUnreachable: return .idle
        }
    }

    // MARK: - Terminal batching

    private func scheduleBatchSend() {
        guard terminalBatchTimer == nil else { return }

        terminalBatchTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushTerminalBatch()
            }
        }
    }

    private func flushTerminalBatch() {
        terminalBatchTimer = nil

        guard !pendingTerminalLines.isEmpty else { return }

        let lines = pendingTerminalLines
        pendingTerminalLines = []

        let update = WatchMessage.TerminalUpdate(lines: lines)
        let message = WatchMessage.terminalUpdate(update)
        sessionManager.send(message)
    }

    // MARK: - Elapsed time

    private func startElapsedTimer() {
        sessionStartDate = sessionStartDate ?? Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartDate else { return }
                self.elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - JSON helpers

    private func parseJSON(_ string: String) -> [String: Any]? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
