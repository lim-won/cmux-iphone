import SwiftUI

struct PairingView: View {

    @EnvironmentObject private var relayService: RelayService

    // MARK: - State

    @State private var code: String = ""
    @State private var ipAddress: String = ""
    // IP + code entry is the default — Bonjour auto-discovery doesn't cross
    // Tailscale/remote networks, and pairing always needs the IP anyway.
    @State private var showManualIP: Bool = true
    @FocusState private var isCodeFocused: Bool
    @FocusState private var isIPFocused: Bool
    @State private var shakeOffset: CGFloat = 0
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isConnecting: Bool = false
    @State private var cursorVisible: Bool = true

    private let cursorTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                mascotIcon
                titleSection

                if showManualIP {
                    ipEntrySection
                }

                digitFields
                discoveryStatus
                statusSection

                Spacer()

                bottomSection
            }
            .padding(.horizontal, 32)
        }
        .onReceive(cursorTimer) { _ in
            cursorVisible.toggle()
        }
    }

    // MARK: - Subviews

    private var mascotIcon: some View {
        AppLogo(size: 64)
    }

    private var titleSection: some View {
        VStack(spacing: 8) {
            Text("Agent iPhone")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Color.textPrimary)

            Text(showManualIP
                 ? "Mac의 IP 주소와 페어링 코드를 입력하세요."
                 : "Mac에 표시된 6자리 페어링 코드를 입력하세요.")
                .font(.system(size: 15))
                .foregroundStyle(Color.subtleText)
                .multilineTextAlignment(.center)
        }
    }

    private var ipEntrySection: some View {
        HStack(spacing: 8) {
            TextField("192.168.1.x 또는 호스트명", text: $ipAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                .tint(Color.claudeOrange)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.fieldBorder, lineWidth: 1)
                )
                .focused($isIPFocused)
        }
    }

    private var digitFields: some View {
        ZStack {
            // Hidden single TextField that captures all input
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($isCodeFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .accentColor(.clear)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: code) { _, newValue in
                    handleCodeChange(newValue)
                }

            // Visual digit boxes
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    DigitBox(
                        character: digitAt(index),
                        isActive: index == code.count && isCodeFocused && !isConnecting,
                        isError: showError,
                        isDisabled: isConnecting,
                        showCursor: cursorVisible
                    )
                }
            }
            .offset(x: shakeOffset)
            .contentShape(Rectangle())
            .onTapGesture {
                isCodeFocused = true
            }
        }
        .onAppear {
            if showManualIP {
                if ipAddress.isEmpty { isIPFocused = true } else { isCodeFocused = true }
            } else {
                isCodeFocused = true
            }
        }
    }

    @ViewBuilder
    private var discoveryStatus: some View {
        if !showManualIP {
            HStack(spacing: 8) {
                Circle()
                    .fill(relayService.machineName != nil ? Color.statusGreen : Color.subtleText.opacity(0.5))
                    .frame(width: 8, height: 8)

                if let name = relayService.machineName {
                    Text("브리지 발견 · \(name)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.subtleText)
                } else {
                    Text("브리지 검색 중…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mutedText)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if isConnecting {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(Color.claudeOrange)
                Text("Mac에 연결 중…")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.subtleText)
            }
            .padding(.top, 4)
        } else if showError {
            Text(errorMessage)
                .font(.system(size: 14))
                .foregroundStyle(errorMessage.contains("만료") ? Color.claudeAmber : Color.denyRed)
                .multilineTextAlignment(.center)
                .transition(.opacity)
                .padding(.top, 4)
        }
    }

    private var bottomSection: some View {
        VStack(spacing: 14) {
            // Hint pill
            HStack(spacing: 8) {
                Text("Mac에서 node server.js 실행")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.subtleText)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.hairline, lineWidth: 1)
            )

            if !showManualIP {
                Button {
                    withAnimation {
                        showManualIP = true
                        isIPFocused = true
                    }
                } label: {
                    Text("연결이 안 되나요? IP 직접 입력")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.claudeOrange)
                }
            }

            if relayService.isAddingMac {
                Button {
                    relayService.cancelAddMac()
                } label: {
                    Text("취소")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.subtleText)
                }
                .padding(.top, 2)
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - Logic

    private func digitAt(_ index: Int) -> Character? {
        guard index < code.count else { return nil }
        return code[code.index(code.startIndex, offsetBy: index)]
    }

    private func handleCodeChange(_ newValue: String) {
        let filtered = String(newValue.filter { $0.isNumber }.prefix(6))
        if filtered != code {
            code = filtered
        }

        if showError {
            withAnimation(.easeOut(duration: 0.2)) {
                showError = false
                errorMessage = ""
            }
        }

        if code.count == 6 && !isConnecting {
            submitCode(code)
        }
    }

    private func submitCode(_ code: String) {
        isConnecting = true
        isCodeFocused = false
        isIPFocused = false

        Task {
            do {
                if showManualIP {
                    let ip = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !ip.isEmpty else {
                        await MainActor.run {
                            showPairingError("Mac의 IP 주소를 입력하세요.")
                        }
                        return
                    }
                    try await relayService.pairWithIP(ip, code: code)
                } else {
                    try await relayService.pair(code: code)
                }
            } catch let error as BridgeClient.BridgeError {
                await MainActor.run { handlePairingError(error) }
            } catch let error as BonjourDiscovery.DiscoveryError {
                await MainActor.run {
                    switch error {
                    case .permissionDenied:
                        showPairingError("로컬 네트워크 접근이 꺼져 있습니다. 설정 → 개인정보 보호 및 보안 → 로컬 네트워크에서 Agent iPhone을 켜고 앱을 재실행하세요.")
                    case .noServiceFound:
                        if !showManualIP {
                            showManualIP = true
                            isIPFocused = true
                        }
                        showPairingError("브리지를 찾지 못했습니다. IP가 맞는지, Mac에서 브리지가 켜져 있는지 확인하세요.")
                    case .timeout:
                        showPairingError("연결 시간 초과. 같은 네트워크/Tailscale 연결을 확인하세요.")
                    case .browsingFailed(let reason):
                        showPairingError("연결 실패: \(reason)")
                    }
                }
            } catch {
                await MainActor.run {
                    showPairingError("연결 실패: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handlePairingError(_ error: BridgeClient.BridgeError) {
        switch error {
        case .invalidCode:
            showPairingError("코드가 올바르지 않습니다. 다시 시도하세요.")
            shakeFields()
        case .expired:
            showPairingError("코드가 만료되었습니다. Mac에서 새 코드가 생성되었습니다.")
        case .rateLimited:
            showPairingError("시도 횟수가 너무 많습니다. 잠시 후 다시 시도하세요.")
        case .networkError:
            if !showManualIP {
                showManualIP = true
                showPairingError("브리지에 연결할 수 없습니다. Mac의 IP 주소를 입력하세요.")
                isIPFocused = true
            } else {
                showPairingError("브리지 서버에 연결할 수 없습니다. IP와 네트워크를 확인하세요.")
            }
        case .serverError(let msg):
            showPairingError(msg)
        }
    }

    private func showPairingError(_ message: String) {
        isConnecting = false
        errorMessage = message
        withAnimation(.easeInOut(duration: 0.3)) {
            showError = true
        }
        code = ""
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if showManualIP && ipAddress.isEmpty {
                isIPFocused = true
            } else {
                isCodeFocused = true
            }
        }
    }

    private func shakeFields() {
        withAnimation(.easeInOut(duration: 0.06).repeatCount(5, autoreverses: true)) {
            shakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            shakeOffset = 0
        }
    }
}

// MARK: - Digit Box (display only)

private struct DigitBox: View {

    let character: Character?
    let isActive: Bool
    let isError: Bool
    let isDisabled: Bool
    let showCursor: Bool

    private var isFilled: Bool { character != nil }

    private var borderColor: Color {
        if isError { return Color.denyRed }
        if isActive { return Color.claudeOrange }
        return Color.hairline
    }

    private var backgroundColor: Color {
        isFilled ? Color.cardBackground : Color.surfaceElevated
    }

    var body: some View {
        ZStack {
            if let character {
                Text(String(character))
                    .font(.system(size: 24, design: .monospaced))
                    .foregroundStyle(isError ? Color.denyRed : Color.textPrimary)
            } else if isActive && showCursor {
                // Blinking cursor on the current/next box
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.claudeOrange)
                    .frame(width: 2, height: 26)
            }
        }
        .frame(width: 44, height: 54)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: isActive ? 2 : 1)
        )
        .opacity(isDisabled ? 0.4 : 1.0)
    }
}

// MARK: - Preview

#Preview {
    PairingView()
        .environmentObject(RelayService.shared)
}
