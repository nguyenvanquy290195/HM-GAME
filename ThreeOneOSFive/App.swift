import SwiftUI
import UIKit
import Foundation
import Darwin

// MARK: - Server-gated IPA build identity

enum HMBuildIdentity {
    static var id: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "HMBuildID") as? String
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "INVALID-BUILD" : value
    }

    static let statusEndpoint = "https://miniapp.shopaccvt.site/proxy/status.php"
}

struct HMBuildStatusResponse: Decodable {
    let ok: Bool
    let code: String
    let message: String
    let buildID: String?
    let currentBuildID: String?
    let serverTime: String?
    let expiresAt: String?
    let remainingSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case ok, code, message
        case buildID = "build_id"
        case currentBuildID = "current_build_id"
        case serverTime = "server_time"
        case expiresAt = "expires_at"
        case remainingSeconds = "remaining_seconds"
    }
}

@MainActor
final class HMBuildGateController: ObservableObject {
    enum State: Equatable {
        case checking
        case allowed(expiresAt: String?, remainingSeconds: Int?)
        case blocked(code: String, message: String, shouldExit: Bool)
    }

    @Published private(set) var state: State = .checking
    private var expiryTask: Task<Void, Never>?
    private var requestInFlight = false

    var isAllowed: Bool {
        if case .allowed = state { return true }
        return false
    }

    func check() async {
        guard !requestInFlight else { return }
        requestInFlight = true
        defer { requestInFlight = false }

        do {
            guard var components = URLComponents(string: HMBuildIdentity.statusEndpoint) else {
                throw URLError(.badURL)
            }
            components.queryItems = [URLQueryItem(name: "build_id", value: HMBuildIdentity.id)]
            guard let url = components.url else { throw URLError(.badURL) }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            let session = URLSession(configuration: configuration)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            let payload = try JSONDecoder().decode(HMBuildStatusResponse.self, from: data)
            if (200...299).contains(http.statusCode), payload.ok {
                state = .allowed(expiresAt: payload.expiresAt, remainingSeconds: payload.remainingSeconds)
                scheduleExpiryCheck(payload.remainingSeconds)
            } else {
                expiryTask?.cancel()
                let exits = ["app_expired", "build_outdated", "app_disabled"].contains(payload.code)
                state = .blocked(code: payload.code, message: payload.message, shouldExit: exits)
            }
        } catch {
            expiryTask?.cancel()
            state = .blocked(
                code: "verification_failed",
                message: "Không thể xác minh thời hạn ứng dụng với máy chủ. Hãy kiểm tra mạng và thử lại.",
                shouldExit: false
            )
        }
    }

    private func scheduleExpiryCheck(_ seconds: Int?) {
        expiryTask?.cancel()
        guard let seconds, seconds > 0 else { return }
        expiryTask = Task { [weak self] in
            let wait = UInt64(seconds + 1) * 1_000_000_000
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled else { return }
            await self?.check()
        }
    }

    func retry() {
        state = .checking
        Task { await check() }
    }
}

struct HMBuildGateView: View {
    let state: HMBuildGateController.State
    let retry: () -> Void
    @State private var exitScheduled = false

    private let accent = Color(red: 1.0, green: 0.72, blue: 0.05)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: iconName)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                if case .checking = state {
                    ProgressView().tint(accent)
                } else if case .blocked(_, _, let shouldExit) = state, !shouldExit {
                    Button("Thử lại") { retry() }
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24)
                        .frame(height: 44)
                        .background(accent, in: Capsule())
                } else if case .blocked(_, _, let shouldExit) = state, shouldExit {
                    Text("Ứng dụng sẽ đóng sau vài giây.")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.36))
                }
            }
        }
        .onAppear { scheduleExitIfNeeded() }
        .onChange(of: state) { _ in scheduleExitIfNeeded() }
    }

    private var title: String {
        switch state {
        case .checking: return "Đang xác minh"
        case .allowed: return "HM GAMING"
        case .blocked(let code, _, _):
            return code == "build_outdated" ? "Cần bản mới" : "Ứng dụng đã khóa"
        }
    }

    private var message: String {
        switch state {
        case .checking: return "Đang kiểm tra Build ID và thời hạn trên máy chủ…"
        case .allowed: return ""
        case .blocked(_, let message, _): return message
        }
    }

    private var iconName: String {
        switch state {
        case .checking: return "checkmark.shield.fill"
        case .allowed: return "checkmark.shield.fill"
        case .blocked: return "lock.shield.fill"
        }
    }

    private func scheduleExitIfNeeded() {
        guard case .blocked(_, _, let shouldExit) = state, shouldExit, !exitScheduled else { return }
        exitScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            exit(0)
        }
    }
}

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var buildGate = HMBuildGateController()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showOnboarding = false
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
        log("app: HM GAMING launching — build \(HMBuildIdentity.id) — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        // Custom build: updates are controlled by HMBuildID on the server.
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if buildGate.isAllowed {
                    ZStack {
                        ContentView()
                            .environmentObject(appState)
                            .environmentObject(patchDraftCoordinator)
                            .environmentObject(fileOperationCoordinator)
                            .environment(\.appLanguage, language)
                            .environment(\.locale, language.locale)
                            .opacity(showOnboarding ? 0 : 1)
                            .allowsHitTesting(!showOnboarding)

                        if showOnboarding {
                            OnboardingView {
                                OnboardingStore.markCompleted()
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                    showOnboarding = false
                                }
                                appState.detectSupport()
                                checkForUpdate()
                            }
                            .environment(\.appLanguage, language)
                            .environment(\.locale, language.locale)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            .zIndex(1)
                        }
                    }
                } else {
                    HMBuildGateView(state: buildGate.state) { buildGate.retry() }
                }
            }
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: buildGate.isAllowed && !showOnboarding)
            .sheet(isPresented: $showAttribution) { DisplayAttributionSheet() }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) { UIApplication.shared.open(offer.url) },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) { AppUpdateChecker.dismiss(version: offer.version) }
                )
            }
            .task { await buildGate.check() }
            .onAppear {
                if buildGate.isAllowed, !showOnboarding {
                    appState.detectSupport()
                    checkForUpdate()
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task { await buildGate.check() }
                if buildGate.isAllowed, !showOnboarding { appState.detectSupport() }
            }
            .onOpenURL { url in
                guard buildGate.isAllowed else { return }
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}
