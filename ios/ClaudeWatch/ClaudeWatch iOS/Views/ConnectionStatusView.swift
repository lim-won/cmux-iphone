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
    @State private var screenHash: String? = nil
    @State private var promptText: String = ""
    @State private var changedNotice = false
    @FocusState private var inputFocused: Bool
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    // Heuristic: does the current screen look like an approval prompt? Only used
    // to decide whether to hash-guard the send (false positives just make the
    // send stricter; false negatives behave like before — no safety regression).
    private var isApprovalScreen: Bool {
        let s = screen.lowercased()
        if s.contains("esc to interrupt") { return false } // agent busy, not an approval
        let markers = ["yes, proceed", "1. yes", "allow this command", "do you want to proceed",
                       "approve?", "(y/n)", "[y/n", "approval", "승인", "허용하"]
        return markers.contains { s.contains($0) }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                screenView
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                if changedNotice { noticeBar } else if isApprovalScreen { approvalBanner }
                inputBar
                    .padding(12)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: terminalId) { await refresh() }
        .onReceive(pollTimer) { _ in Task { await refresh() } }
        .onChange(of: relayService.cmuxScreenTick) { _, _ in Task { await refresh() } }
    }

    private func refresh() async {
        if let s = await relayService.cmuxScreen(terminalId) {
            screen = s.text
            screenHash = s.hash
        }
    }

    private var approvalBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "shield.lefthalf.filled").foregroundStyle(Color.claudeAmber)
            Text("승인 화면 감지 — 현재 화면 기준으로 안전 전송됩니다")
                .font(.system(size: 11))
                .foregroundStyle(Color.claudeAmber)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var noticeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.denyRed)
            Text("화면이 바뀌어 전송을 취소했습니다. 확인 후 다시 보내세요.")
                .font(.system(size: 11))
                .foregroundStyle(Color.denyRed)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private var screenView: some View {
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
        .frame(maxWidth: .infinity)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func send() {
        let t = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }

        // Approval screen → hash-guarded send so the response can't land on a
        // changed screen. Normal prompt → fire-and-forget (screen keeps moving).
        if isApprovalScreen {
            let expected = screenHash
            Task {
                let result = await relayService.sendCmuxGuarded(terminalId: terminalId, text: t, expectedScreenHash: expected)
                switch result {
                case .sent:
                    promptText = ""
                    inputFocused = false
                    changedNotice = false
                case .screenChanged(let newText, let newHash):
                    screen = newText            // show what's actually on screen now
                    screenHash = newHash
                    changedNotice = true        // keep promptText so the user can re-confirm
                case .failed:
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refresh()
            }
        } else {
            relayService.sendCmux(terminalId: terminalId, text: t)
            promptText = ""
            inputFocused = false
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refresh()
            }
        }
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
