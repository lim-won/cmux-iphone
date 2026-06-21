import SwiftUI
import UIKit

// MARK: - Navigation routes
//
// Hierarchy: Office (Mac) → Workspace (project folder) → Session → full content.
// One Mac is connected at a time; tapping an office switches the active bridge.

private struct OfficeRoute: Hashable { let id: UUID }
private struct FolderRoute: Hashable { let folder: String }
private struct SessionRoute: Hashable { let sessionId: String }
// cmux mirror routes (when the Mac runs cmux): Office → Workspace → Terminal
private struct CmuxWorkspaceRoute: Hashable { let id: String }
private struct CmuxTerminalRoute: Hashable { let id: String; let title: String }

// MARK: - cmux mirror models (decoded from GET /cmux/tree)

struct CmuxTreeResponse: Decodable {
    let available: Bool
    let workspaces: [CmuxWorkspace]
}

struct CmuxWorkspace: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let cwd: String?
    let selected: Bool
    let hasUnread: Bool
    let preview: String?
    let terminals: [CmuxTerminal]
}

struct CmuxTerminal: Identifiable, Decodable, Equatable {
    let id: String
    let title: String
    let cwd: String?
    let focused: Bool
    let ready: Bool
}

/// Workspace key for a session: project folder name, falling back to the cwd's
/// last path component, then a placeholder.
fileprivate func workspaceKey(_ s: AgentSession) -> String {
    if !s.folderName.isEmpty { return s.folderName }
    let leaf = (s.cwd as NSString).lastPathComponent
    return leaf.isEmpty ? "(unknown)" : leaf
}

// MARK: - Root: Offices (Macs) — SCREEN 02

struct ConnectionStatusView: View {

    @EnvironmentObject private var relayService: RelayService
    @EnvironmentObject private var sessionManager: WatchSessionManager
    @ObservedObject private var store = ConnectionStore.shared

    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showApprovalQueue = false
    @State private var renameTarget: SavedConnection?
    @State private var renameText = ""
    @State private var deleteTarget: SavedConnection?

    private var connectedCount: Int {
        (store.activeID != nil || store.connections.isEmpty)
            && relayService.connectionState == .connected ? 1 : 0
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                officesList
            }
            .navigationTitle("오피스")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if relayService.pendingApprovalCount > 0 {
                        Button {
                            showApprovalQueue = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "bell.badge.fill")
                                    .foregroundStyle(Color.claudeAmber)
                                Text("\(relayService.pendingApprovalCount)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.denyRed, in: Capsule())
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
            .navigationDestination(for: OfficeRoute.self) { _ in
                WorkspacesView()
            }
            .navigationDestination(for: FolderRoute.self) { route in
                SessionsListView(folder: route.folder)
            }
            .navigationDestination(for: SessionRoute.self) { route in
                SessionDetailView(sessionId: route.sessionId)
            }
            .navigationDestination(for: CmuxWorkspaceRoute.self) { route in
                CmuxTerminalsView(workspaceId: route.id)
            }
            .navigationDestination(for: CmuxTerminalRoute.self) { route in
                CmuxTerminalView(terminalId: route.id, title: route.title)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(relayService)
        }
        .sheet(isPresented: $showApprovalQueue) {
            ApprovalQueueView().environmentObject(relayService)
        }
        .onChange(of: relayService.pendingApprovalCount) { oldCount, newCount in
            // Auto-present the approval card on ANY screen when a new one arrives
            // (matches the LAN web client's popup UX). Auto-closes when cleared.
            if newCount > oldCount {
                showApprovalQueue = true
            } else if newCount == 0 {
                showApprovalQueue = false
            }
        }
        .alert("오피스 이름 변경", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("이름 (예: office-1)", text: $renameText)
            Button("저장") {
                if let t = renameTarget, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    store.rename(t.id, to: renameText.trimmingCharacters(in: .whitespaces))
                    if t.id == store.activeID { relayService.refreshActiveName() }
                }
                renameTarget = nil
            }
            Button("취소", role: .cancel) { renameTarget = nil }
        }
        .alert("오피스 삭제", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("삭제", role: .destructive) {
                if let t = deleteTarget {
                    if t.id == store.activeID {
                        relayService.forgetActive()
                    } else {
                        store.remove(t.id)
                    }
                }
                deleteTarget = nil
            }
            Button("취소", role: .cancel) { deleteTarget = nil }
        } message: {
            if let t = deleteTarget {
                Text("\(t.name) (\(t.host):\(t.port)) 연결을 삭제할까요?")
            }
        }
    }

    // MARK: Offices list

    @ViewBuilder
    private var officesList: some View {
        ScrollView {
            VStack(spacing: 12) {
                subtitleHeader

                if store.connections.isEmpty {
                    // Legacy pairing with no saved connection — one implicit office.
                    officeRow(
                        name: relayService.machineName ?? "Mac",
                        subtitle: nil,
                        isActive: true,
                        onTap: { path.append(OfficeRoute(id: UUID())) }
                    )
                } else {
                    ForEach(store.connections) { conn in
                        officeRow(
                            name: conn.name,
                            subtitle: "\(conn.host):\(conn.port)",
                            isActive: conn.id == store.activeID,
                            onTap: {
                                if conn.id != store.activeID {
                                    relayService.switchTo(conn)
                                }
                                path.append(OfficeRoute(id: conn.id))
                            }
                        )
                        .contextMenu {
                            Button {
                                renameText = conn.name
                                renameTarget = conn
                            } label: { Label("이름 변경", systemImage: "pencil") }
                            Button(role: .destructive) {
                                deleteTarget = conn
                            } label: { Label("삭제", systemImage: "trash") }
                        }
                    }
                }

                addMacButton
            }
            .padding(16)
        }
    }

    private var subtitleHeader: some View {
        let total = store.connections.isEmpty ? 1 : store.connections.count
        return HStack {
            Text("Mac \(total)대 · \(connectedCount)대 연결됨")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var addMacButton: some View {
        Button {
            relayService.beginAddMac()
        } label: {
            HStack(spacing: 6) {
                Text("+ 다른 Mac 추가")
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.claudeOrange)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.claudeOrange.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: [5])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func officeRow(name: String, subtitle: String?, isActive: Bool, onTap: @escaping () -> Void) -> some View {
        let connected = isActive && relayService.connectionState == .connected
        let connecting = isActive && relayService.connectionState == .connecting
        let sessionCount = isActive ? relayService.sessions.count : nil
        let folderCount = isActive
            ? Set(relayService.sessions.map { workspaceKey($0) }).count
            : nil
        let dotColor: Color = connected
            ? Color.statusGreen
            : (connecting ? Color.claudeAmber : Color.subtleText.opacity(0.5))
        let borderColor: Color = isActive ? Color.claudeOrange.opacity(0.35) : Color.hairline

        return Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.surfaceElevated)
                        .frame(width: 36, height: 36)
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 18))
                        .foregroundStyle(isActive ? Color.claudeOrange : Color.subtleText)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.subtleText)
                            .lineLimit(1)
                    }
                    if isActive, connected, let sessionCount, let folderCount {
                        Text("워크스페이스 \(folderCount) · 세션 \(sessionCount)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.subtleText)
                    } else if isActive, connecting {
                        Text("연결 중…")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.claudeAmber)
                    } else {
                        Text("탭하여 연결")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.subtleText)
                    }
                }

                Spacer()

                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.subtleText)
            }
            .padding(14)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Level 2: Workspaces (folders) for the active Mac — SCREEN 03 / 08

private struct WorkspacesView: View {
    @EnvironmentObject private var relayService: RelayService

    /// Sessions grouped by workspace key, order preserved by first appearance.
    private var folders: [(key: String, sessions: [AgentSession])] {
        var order: [String] = []
        var map: [String: [AgentSession]] = [:]
        for s in relayService.sessions {
            let k = workspaceKey(s)
            if map[k] == nil { order.append(k) }
            map[k, default: []].append(s)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if relayService.cmuxAvailable {
                cmuxWorkspaceList
            } else if relayService.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        header
                        ForEach(folders, id: \.key) { folder in
                            NavigationLink(value: FolderRoute(folder: folder.key)) {
                                folderRow(folder.key, sessions: folder.sessions)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(relayService.machineName ?? "Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if relayService.connectionState == .connected {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.statusGreen).frame(width: 7, height: 7)
                        Text("연결됨")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.subtleText)
                    }
                }
            }
        }
        .onAppear { relayService.refreshCmuxTree() }
    }

    // MARK: cmux mirror — workspaces list

    private var cmuxWorkspaceList: some View {
        ScrollView {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(relayService.machineName ?? "cmux")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text("워크스페이스 \(relayService.cmuxWorkspaces.count)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.subtleText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(relayService.cmuxWorkspaces) { ws in
                    NavigationLink(value: CmuxWorkspaceRoute(id: ws.id)) {
                        cmuxWorkspaceRow(ws)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }

    private func cmuxWorkspaceRow(_ ws: CmuxWorkspace) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 18))
                .foregroundStyle(Color.claudeOrange.opacity(0.9))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(ws.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let preview = ws.preview, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.claudeAmber)
                        .lineLimit(1)
                } else {
                    Text("\(ws.terminals.count) sessions")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.subtleText)
                }
            }

            Spacer()
            if ws.hasUnread {
                Circle().fill(Color.claudeAmber).frame(width: 8, height: 8)
            } else if ws.selected {
                Circle().fill(Color.statusGreen).frame(width: 8, height: 8)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText.opacity(0.6))
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(ws.selected ? Color.claudeOrange.opacity(0.35) : Color.hairline, lineWidth: 1)
        )
    }

    private var header: some View {
        let folderCount = folders.count
        let sessionCount = relayService.sessions.count
        return VStack(alignment: .leading, spacing: 4) {
            Text(relayService.machineName ?? "Workspaces")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text("워크스페이스 \(folderCount) · 세션 \(sessionCount)")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    // SCREEN 08 — empty state
    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            AppLogo(size: 96)
            Text("세션을 기다리는 중")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text("Mac에서 Claude Code 세션을 시작하세요 — 도구 호출과 승인이 여기에 실시간으로 표시됩니다.")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            HStack(spacing: 6) {
                Circle().fill(Color.statusGreen).frame(width: 7, height: 7)
                Text("\(relayService.machineName ?? "이 Mac")에서 수신 중")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
            }
            Spacer()
            HStack(spacing: 0) {
                Text("아무 프로젝트 폴더에서 ")
                    .foregroundStyle(Color.subtleText)
                Text("claude")
                    .foregroundStyle(Color.claudeOrange)
                Text(" 실행")
                    .foregroundStyle(Color.subtleText)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.hairline, lineWidth: 1)
            )
            .padding(.bottom, 24)
        }
    }

    private func folderRow(_ name: String, sessions: [AgentSession]) -> some View {
        let running = sessions.contains { $0.activity == .running }
        let waitingApproval = sessions.contains { $0.activity == .waitingApproval }
        let dot: Color = waitingApproval
            ? Color.claudeAmber
            : (running ? Color.statusGreen : Color.subtleText.opacity(0.5))
        let iconTint: Color = (running || waitingApproval) ? Color.claudeOrange : Color.subtleText
        let cwd = sessions.first?.cwd ?? ""

        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.surfaceElevated)
                    .frame(width: 36, height: 36)
                Image(systemName: "folder.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(iconTint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if waitingApproval {
                    Text("승인 대기 중")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.claudeAmber)
                } else if !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
            Text("\(sessions.count)")
                .font(.system(size: 13))
                .foregroundStyle(Color.subtleText)
            Circle().fill(dot).frame(width: 8, height: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Level 3: Sessions in a folder — SCREEN 04

// MARK: - cmux mirror: terminals in a workspace

private struct CmuxTerminalsView: View {
    let workspaceId: String
    @EnvironmentObject private var relayService: RelayService

    private var workspace: CmuxWorkspace? {
        relayService.cmuxWorkspaces.first { $0.id == workspaceId }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if let ws = workspace {
                ScrollView {
                    VStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ws.title)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Color.textPrimary)
                                .lineLimit(2)
                            Text("\(ws.terminals.count) sessions")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.subtleText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        ForEach(ws.terminals) { t in
                            NavigationLink(value: CmuxTerminalRoute(id: t.id, title: t.title)) {
                                terminalRow(t)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            } else {
                Text("워크스페이스를 찾을 수 없습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtleText)
            }
        }
        .navigationTitle(workspace?.title ?? "Workspace")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { relayService.refreshCmuxTree() }
    }

    private func terminalRow(_ t: CmuxTerminal) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 15))
                .foregroundStyle(t.focused ? Color.claudeOrange : Color.subtleText)
                .frame(width: 30, height: 30)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(t.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let cwd = t.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
            if t.focused { Circle().fill(Color.statusGreen).frame(width: 7, height: 7) }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText.opacity(0.6))
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - cmux mirror: live terminal screen + prompt input

private struct CmuxTerminalView: View {
    let terminalId: String
    let title: String
    @EnvironmentObject private var relayService: RelayService

    @State private var screen: String = ""
    @State private var promptText: String = ""
    @State private var showModelSheet = false
    @State private var codexDriving = false
    @State private var codexStatus = ""
    @FocusState private var inputFocused: Bool
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 10) {
                terminalCard
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                inputBar
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            if showModelSheet {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { if !codexDriving { closeModelSheet() } }
                    .transition(.opacity)

                ModelEffortPanel(
                    initialAgent: detectAgent(from: screen),
                    liveScreen: screen,
                    driving: codexDriving,
                    statusText: codexStatus,
                    onClaudeCommand: { cmd in
                        closeModelSheet()
                        relayService.sendCmux(terminalId: terminalId, text: cmd)
                        Task { try? await Task.sleep(nanoseconds: 600_000_000); await refresh() }
                    },
                    onCodexSelect: { model, effort in driveCodex(model: model, effort: effort) },
                    onKey: { key in
                        Task {
                            await relayService.sendCmuxKey(terminalId: terminalId, key: key)
                            try? await Task.sleep(nanoseconds: 250_000_000); await refresh()
                        }
                    },
                    onDigit: { digit in
                        Task {
                            await relayService.sendCmuxText(terminalId: terminalId, text: digit, submit: false)
                            try? await Task.sleep(nanoseconds: 250_000_000); await refresh()
                        }
                    },
                    onDismiss: { closeModelSheet() }
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: showModelSheet)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { showModelSheet = true }
                } label: {
                    Image(systemName: "cpu").foregroundStyle(Color.claudeOrange)
                }
            }
        }
        .task(id: terminalId) { await refresh() }
        .onReceive(pollTimer) { _ in Task { await refresh() } }
        .onChange(of: relayService.cmuxScreenTick) { _, _ in Task { await refresh() } }
    }

    private func refresh() async {
        if let s = await relayService.cmuxScreen(terminalId) {
            screen = s.text
        }
    }

    private func closeModelSheet() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { showModelSheet = false }
    }

    // Best-effort guess of the agent running in this terminal, from its live
    // screen. Only a seed for the Claude/Codex toggle — the user can flip it.
    // (Avoids "claude" matching the claude-watch cwd by requiring strong markers.)
    private func detectAgent(from screen: String) -> String {
        let s = screen.lowercased()
        if s.contains("openai codex") || s.contains("codex cli") || s.contains("gpt-5") { return "codex" }
        if s.contains("claude code") || s.contains("anthropic") { return "claude" }
        return "claude"
    }

    // MARK: codex /model picker driver
    //
    // codex's "/model" is an interactive popup (no inline args), so we open it,
    // read the rendered rows, and pick by the on-screen digit (position-proof).
    // If a row can't be parsed we leave the popup open for the manual keypad —
    // never blind-firing a guess into a live session.
    private func driveCodex(model: String, effort: String?) {
        guard !codexDriving else { return }
        codexDriving = true
        codexStatus = "모델 선택 중…"
        Task {
            defer { codexDriving = false }
            let tid = terminalId

            // 1) open the picker
            await relayService.sendCmuxText(terminalId: tid, text: "/model", submit: true)
            try? await Task.sleep(nanoseconds: 750_000_000)
            await refresh()
            var scr = (await relayService.cmuxScreen(tid))?.text ?? ""

            // 2) expand "All models" first if our concrete model isn't listed yet
            if codexDigit(for: model, in: scr) == nil,
               let allDigit = codexDigit(for: "all models", in: scr) {
                await relayService.sendCmuxText(terminalId: tid, text: allDigit, submit: false)
                try? await Task.sleep(nanoseconds: 550_000_000)
                await refresh()
                scr = (await relayService.cmuxScreen(tid))?.text ?? ""
            }

            // 3) pick the model row by its on-screen digit
            guard let modelDigit = codexDigit(for: model, in: scr) else {
                codexStatus = "자동 실패 — 아래 키패드로 직접 선택하세요"
                return   // leave the popup open; manual keypad takes over
            }
            await relayService.sendCmuxText(terminalId: tid, text: modelDigit, submit: false)
            try? await Task.sleep(nanoseconds: 750_000_000)
            await refresh()
            scr = (await relayService.cmuxScreen(tid))?.text ?? ""

            // 4) reasoning-effort stage — only if the popup actually advanced to it
            if let effort, scr.lowercased().contains("reasoning"),
               let effortDigit = codexDigit(for: effort, in: scr, wholeWord: true) {
                await relayService.sendCmuxText(terminalId: tid, text: effortDigit, submit: false)
                try? await Task.sleep(nanoseconds: 450_000_000)
                await refresh()
            }

            codexStatus = "완료"
            try? await Task.sleep(nanoseconds: 600_000_000)
            closeModelSheet()
            await refresh()
        }
    }

    // Find the leading row-number for the picker row matching `label`. Scans only
    // the text *before* the label so "gpt-5.5" never returns the "5" in its name;
    // stops at a word boundary so it won't grab a digit from an earlier token.
    // `wholeWord` rejects substring hits (so "high" won't match the "xhigh" row).
    private func codexDigit(for label: String, in screen: String, wholeWord: Bool = false) -> String? {
        let needle = label.lowercased()
        for raw in screen.split(separator: "\n") {
            let line = String(raw).lowercased()
            guard let r = line.range(of: needle) else { continue }
            if wholeWord {
                let beforeOK = r.lowerBound == line.startIndex || !line[line.index(before: r.lowerBound)].isLetter
                let afterOK = r.upperBound == line.endIndex || !line[r.upperBound].isLetter
                if !(beforeOK && afterOK) { continue }
            }
            for ch in line[..<r.lowerBound].reversed() {
                if let d = ch.wholeNumberValue, (1...9).contains(d) { return String(d) }
                if ch.isLetter { break }
            }
        }
        return nil
    }

    // MARK: terminal card (chrome + screen)

    private var terminalCard: some View {
        VStack(spacing: 0) {
            // window header — traffic lights + title
            HStack(spacing: 6) {
                Circle().fill(Color.denyRed.opacity(0.85)).frame(width: 10, height: 10)
                Circle().fill(Color.claudeAmber.opacity(0.85)).frame(width: 10, height: 10)
                Circle().fill(Color.statusGreen.opacity(0.85)).frame(width: 10, height: 10)
                Text(title)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.surfaceElevated)

            Rectangle().fill(Color.hairline).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(screen.isEmpty ? "…" : screen)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onChange(of: screen) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.hairline, lineWidth: 1))
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("프롬프트 입력…", text: $promptText, axis: .vertical)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .tint(Color.claudeOrange)
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.hairline, lineWidth: 1))
                .focused($inputFocused)

            Button { send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.subtleText.opacity(0.4) : Color.claudeOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // Send the prompt to the terminal (the screen is expected to keep changing).
    private func send() {
        let t = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        relayService.sendCmux(terminalId: terminalId, text: t)
        promptText = ""
        inputFocused = false
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refresh()
        }
    }
}

/// Model + effort picker — centered overlay modal, agent-aware.
///
/// Claude mode sends `/model <name>` / `/effort <level>` slash commands (Claude
/// accepts inline args). Codex mode drives the interactive `/model` popup: tap a
/// model to auto-select (parent reads the screen and picks by digit), or use the
/// manual keypad while watching the live screen preview. A Claude/Codex segmented
/// toggle (seeded by a screen heuristic) lets the user pick the right mode.
private struct ModelEffortPanel: View {
    let liveScreen: String
    let driving: Bool
    let statusText: String
    let onClaudeCommand: (String) -> Void
    let onCodexSelect: (_ model: String, _ effort: String?) -> Void
    let onKey: (String) -> Void
    let onDigit: (String) -> Void
    let onDismiss: () -> Void

    @State private var agent: String
    @State private var pendingEffort: String? = nil

    init(initialAgent: String,
         liveScreen: String,
         driving: Bool,
         statusText: String,
         onClaudeCommand: @escaping (String) -> Void,
         onCodexSelect: @escaping (String, String?) -> Void,
         onKey: @escaping (String) -> Void,
         onDigit: @escaping (String) -> Void,
         onDismiss: @escaping () -> Void) {
        self.liveScreen = liveScreen
        self.driving = driving
        self.statusText = statusText
        self.onClaudeCommand = onClaudeCommand
        self.onCodexSelect = onCodexSelect
        self.onKey = onKey
        self.onDigit = onDigit
        self.onDismiss = onDismiss
        _agent = State(initialValue: initialAgent)
    }

    private let claudeModels: [(String, String)] = [("Opus", "opus"), ("Sonnet", "sonnet"), ("Haiku", "haiku")]
    private let claudeEfforts: [String] = ["low", "medium", "high", "xhigh", "max", "ultracode"]
    // Labels match codex's "/model" popup rows exactly (verified live, v0.141.0).
    // Other models need `codex -m <name>`; pick them via the keypad if listed.
    private let codexModels: [String] = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini"]
    private let codexEfforts: [String] = ["Minimal", "Low", "Medium", "High", "Extra high"]
    private let cols = [GridItem(.adaptive(minimum: 88), spacing: 8)]
    private let keypadCols = [GridItem(.adaptive(minimum: 40), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("", selection: $agent) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }
            .pickerStyle(.segmented)
            .disabled(driving)

            if agent == "claude" { claudeBody } else { codexBody }
        }
        .padding(20)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 6)
        .padding(.horizontal, 24)
    }

    private var header: some View {
        HStack {
            Text(agent == "codex" ? "Codex 설정" : "Claude 설정")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.subtleText)
            }
            .buttonStyle(.plain)
            .disabled(driving)
        }
    }

    // MARK: Claude

    private var claudeBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("모델") {
                ForEach(claudeModels, id: \.1) { (label, name) in
                    chip(label, color: .claudeOrange) { onClaudeCommand("/model \(name)") }
                }
            }
            section("Effort") {
                ForEach(claudeEfforts, id: \.self) { lvl in
                    chip(lvl, color: .claudeAmber) { onClaudeCommand("/effort \(lvl)") }
                }
            }
            Text("선택하면 Claude에 슬래시 명령으로 전송됩니다.")
                .font(.system(size: 11))
                .foregroundStyle(Color.subtleText)
        }
    }

    // MARK: Codex

    private var codexBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("모델 — 탭하면 자동 선택") {
                    ForEach(codexModels, id: \.self) { m in
                        chip(m, color: .claudeOrange, disabled: driving) { onCodexSelect(m, pendingEffort) }
                    }
                }
                section("Reasoning · effort (모델과 함께 적용)") {
                    ForEach(codexEfforts, id: \.self) { e in
                        chip(e, color: .claudeAmber, selected: pendingEffort == e, disabled: driving) {
                            pendingEffort = (pendingEffort == e) ? nil : e
                        }
                    }
                }

                if !statusText.isEmpty {
                    HStack(spacing: 6) {
                        if driving { ProgressView().scaleEffect(0.7) }
                        Text(statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(driving ? Color.subtleText : Color.claudeAmber)
                    }
                }

                screenPreview
                keypad

                Text("자동이 안 되면 위 키패드로 팝업을 직접 조작하세요 (화면을 보며 ↑↓·숫자·⏎).")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.subtleText)
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 460)
    }

    private var screenPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("화면 (실시간)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.subtleText)
            ScrollView {
                Text(previewTail.isEmpty ? "…" : previewTail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 116)
            .padding(8)
            .background(Color.appBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
        }
    }

    private var keypad: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("수동 키패드")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.subtleText)
            HStack(spacing: 8) {
                keyButton("↑") { onKey("up") }
                keyButton("↓") { onKey("down") }
                keyButton("⏎") { onKey("enter") }
                keyButton("esc") { onKey("escape") }
            }
            LazyVGrid(columns: keypadCols, spacing: 8) {
                ForEach(1...9, id: \.self) { n in
                    keyButton("\(n)") { onDigit("\(n)") }
                }
            }
        }
    }

    private var previewTail: String {
        let lines = liveScreen.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(40).joined(separator: "\n")
    }

    // MARK: shared chrome

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.subtleText)
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) { content() }
        }
    }

    private func chip(_ label: String, color: Color, selected: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(color.opacity(selected ? 0.32 : 0.14))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(selected ? 0.9 : 0.4), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func keyButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(driving)
        .opacity(driving ? 0.5 : 1)
    }
}

private struct SessionsListView: View {
    let folder: String
    @EnvironmentObject private var relayService: RelayService

    private var sessions: [AgentSession] {
        relayService.sessions.filter { workspaceKey($0) == folder }
    }

    private var cwd: String { sessions.first?.cwd ?? "" }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if sessions.isEmpty {
                Text("이 워크스페이스에 세션이 없습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtleText)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        header
                        ForEach(sessions) { session in
                            NavigationLink(value: SessionRoute(sessionId: session.id)) {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(folder)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(folder)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Text("\(cwd) · 세션 \(sessions.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.subtleText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        let lastText = session.terminalLines.last?.text
        let lastAction: String = {
            guard let t = lastText, !t.isEmpty else { return "—" }
            return t.count > 40 ? String(t.prefix(40)) + "…" : t
        }()
        let hasApproval = session.pendingApproval != nil
        let borderColor: Color = hasApproval ? Color.claudeOrange.opacity(0.35) : Color.hairline

        return HStack(spacing: 12) {
            sessionAvatar(session.agent, size: avatarGlyphSize(session.agent))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.agent.rawValue.capitalized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    if hasApproval {
                        Text("승인")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.claudeAmber)
                            .clipShape(Capsule())
                    }
                }
                Text(lastAction)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
            Circle().fill(statusColor(session.activity)).frame(width: 8, height: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.subtleText)
        }
        .padding(14)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private func statusColor(_ activity: SessionActivity) -> Color {
        switch activity {
        case .running:         return Color.statusGreen
        case .waitingApproval: return Color.claudeAmber
        case .ended:           return Color.denyRed
        case .idle:            return Color.subtleText
        }
    }
}

// MARK: - Shared avatar (Claude / Codex)

private func avatarGlyphSize(_ agent: AgentType) -> CGFloat {
    agent == .claude ? 26 : 22
}

@ViewBuilder
private func sessionAvatar(_ agent: AgentType, size: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8)
            .fill(agent == .claude ? Color.claudeOrange.opacity(0.15) : Color.surfaceElevated)
            .frame(width: 40, height: 40)
        switch agent {
        case .claude: AppLogo(size: size)
        case .codex:  CodexLogo(size: size)
        }
    }
}

// MARK: - Level 4: Full session content — SCREEN 05 / 06

private struct SessionDetailView: View {
    let sessionId: String
    @EnvironmentObject private var relayService: RelayService

    @State private var cursorVisible = true
    @State private var promptText = ""
    @State private var messageText = ""
    @FocusState private var isPromptFocused: Bool
    @FocusState private var isMessageFocused: Bool
    private let cursorTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var session: AgentSession? {
        relayService.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if let session {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 10) {
                            headerRow(session)
                            if let approval = session.pendingApproval {
                                approvalPrompt(approval)
                            }
                            terminalView(session)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                    }
                    messageBar(session)
                }
            } else {
                Text("세션이 종료되었습니다.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.subtleText)
            }
        }
        .navigationTitle(session.map { workspaceKey($0) } ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    relayService.clearTerminal(sessionId: sessionId)
                } label: {
                    Image(systemName: "trash").foregroundStyle(Color.subtleText)
                }
            }
        }
    }

    // MARK: Header

    private func headerRow(_ session: AgentSession) -> some View {
        let (label, dot): (String, Color) = {
            switch session.activity {
            case .running:         return ("실행 중", Color.statusGreen)
            case .waitingApproval: return ("승인 대기", Color.claudeAmber)
            case .ended:           return ("완료", Color.denyRed)
            case .idle:            return ("대기", Color.subtleText)
            }
        }()

        return HStack(spacing: 12) {
            sessionAvatar(session.agent, size: session.agent == .claude ? 28 : 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.agent.rawValue.capitalized)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: 6) {
                    Circle().fill(dot).frame(width: 8, height: 8)
                    Text("\(label) · \(workspaceKey(session))")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.subtleText)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Terminal — full output, as-is, selectable.

    private func terminalView(_ session: AgentSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(session.terminalLines) { line in
                        terminalLineView(line)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    if relayService.isThinking {
                        HStack(spacing: 0) {
                            Text("✳ 생각 중… ")
                            Text(cursorVisible ? "\u{258C}" : " ")
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.claudeOrange)
                        .onReceive(cursorTimer) { _ in cursorVisible.toggle() }
                        .id("thinking-cursor")
                    }
                }
                .padding(12)
            }
            .onChange(of: session.terminalLines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if relayService.isThinking {
                        proxy.scrollTo("thinking-cursor", anchor: .bottom)
                    } else if let last = session.terminalLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func terminalLineView(_ line: TerminalLine) -> some View {
        let text = line.text.isEmpty ? " " : line.text
        switch line.type {
        case .command:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("●")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.claudeOrange)
                Text(text)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
            }
        case .system:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.subtleText)
        case .output:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(outputColor(text))
        case .thinking:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.claudeOrange.opacity(0.5))
        case .error:
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.denyRed)
        }
    }

    private func outputColor(_ text: String) -> Color {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+ ") { return Color.statusGreen }
        if t.hasPrefix("- ") { return Color.denyRed }
        return Color.textPrimary
    }

    // MARK: Message bar — SCREEN 05

    private func messageBar(_ session: AgentSession) -> some View {
        let placeholder = session.agent == .codex
            ? "Codex에게 메시지 보내기..."
            : "Claude에게 메시지 보내기..."
        let disabled = messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return HStack(spacing: 10) {
            TextField(placeholder, text: $messageText)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .tint(Color.claudeOrange)
                .focused($isMessageFocused)
                .submitLabel(.send)
                .onSubmit { sendMessage() }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.hairline, lineWidth: 1)
                )

            Button { sendMessage() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.claudeOrange.opacity(disabled ? 0.4 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.appBackground)
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        relayService.sendCommand(text: text, sessionId: sessionId)
        messageText = ""
        isMessageFocused = false
    }

    // MARK: Approval — SCREEN 06

    private func approvalPrompt(_ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.claudeAmber)
                    .font(.system(size: 14))
                Text(approval.question ?? "Claude가 명령을 실행하려고 합니다")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !approval.actionSummary.isEmpty && approval.actionSummary != approval.toolName {
                Text(approval.actionSummary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ForEach(Array(approval.options.enumerated()), id: \.element.id) { index, option in
                let color = colorForOption(index, total: approval.options.count)
                Button {
                    relayService.respond(to: approval, optionLabel: option.label, index: index)
                    promptText = ""
                } label: {
                    HStack(spacing: 8) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.textPrimary)
                            if let desc = option.description, !desc.isEmpty {
                                Text(desc)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.subtleText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(color.opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                TextField("응답 입력...", text: $promptText)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .tint(Color.claudeOrange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.hairline, lineWidth: 1)
                    )
                    .focused($isPromptFocused)
                    .onSubmit { submitPromptText(approval) }

                Button { submitPromptText(approval) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.subtleText : Color.claudeOrange)
                }
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.claudeAmber.opacity(0.4), lineWidth: 1)
        )
    }

    private func submitPromptText(_ approval: ApprovalRequest) {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        relayService.respond(to: approval, optionLabel: text, index: -1)
        promptText = ""
        isPromptFocused = false
    }

    private func colorForOption(_ index: Int, total: Int) -> Color {
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return Color.denyRed }
        return Color.claudeOrange
    }
}

// MARK: - Preview

#Preview {
    ConnectionStatusView()
        .environmentObject(WatchSessionManager.shared)
        .environmentObject(RelayService.shared)
}
