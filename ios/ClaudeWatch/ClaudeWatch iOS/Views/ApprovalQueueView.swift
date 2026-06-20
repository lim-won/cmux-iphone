import SwiftUI

/// App-wide approval queue: every pending approval across the active Mac's
/// sessions, answerable in one place. Backed by `RelayService.approvalQueue`.
struct ApprovalQueueView: View {
    @EnvironmentObject private var relayService: RelayService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                if relayService.approvalQueue.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(relayService.approvalQueue) { approval in
                                ApprovalCard(approval: approval)
                                    .environmentObject(relayService)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("승인 대기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .foregroundStyle(Color.claudeOrange)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.statusGreen)
            Text("대기 중인 승인이 없습니다")
                .font(.system(size: 15))
                .foregroundStyle(Color.subtleText)
        }
    }
}

/// A single approval card — context (Mac · project · agent · cwd · reason) plus
/// the agent's option buttons. Shared by the queue and could back per-session UI.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    @EnvironmentObject private var relayService: RelayService

    private var projectName: String {
        if let cwd = approval.cwd, !cwd.isEmpty {
            let leaf = (cwd as NSString).lastPathComponent
            return leaf.isEmpty ? cwd : leaf
        }
        return "(unknown)"
    }

    private var agentIcon: String {
        switch (approval.agent ?? "").lowercased() {
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "sparkles"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Context header — which Mac / project / agent this came from
            HStack(spacing: 6) {
                Image(systemName: agentIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.claudeOrange)
                Text(approval.macName ?? "Mac")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text("·").foregroundStyle(Color.subtleText)
                Text(projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
                Spacer()
            }

            // Question / title
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.claudeAmber)
                    .font(.system(size: 14))
                Text(approval.question ?? "\(approval.toolName) 실행을 승인할까요?")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action summary (command / file)
            if !approval.actionSummary.isEmpty && approval.actionSummary != approval.toolName {
                Text(approval.actionSummary)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Reason (if the agent supplied one)
            if let reason = approval.reason, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.subtleText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Working directory
            if let cwd = approval.cwd, !cwd.isEmpty {
                Text(cwd)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Options — Allow / (Allow this session) / Deny, or AskUserQuestion choices
            ForEach(Array(approval.options.enumerated()), id: \.element.id) { index, option in
                let color = colorForOption(index, total: approval.options.count)
                Button {
                    relayService.respond(to: approval, optionLabel: option.label, index: index)
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
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.claudeAmber.opacity(0.4), lineWidth: 1)
        )
    }

    private func colorForOption(_ index: Int, total: Int) -> Color {
        if total <= 1 { return Color.statusGreen }
        if index == 0 { return Color.statusGreen }
        if index == total - 1 { return Color.denyRed }
        return Color.claudeOrange
    }
}
