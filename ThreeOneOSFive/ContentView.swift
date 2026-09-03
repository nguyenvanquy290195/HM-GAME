import SwiftUI
import UIKit
import BackgroundTasks

struct HMOnlineGame: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let bundleID: String
    let iconURL: String
    let sortOrder: Int
    let system: Bool

    static let freeFireFallback = HMOnlineGame(
        id: "freefire",
        name: "Free Fire",
        bundleID: "com.dts.freefireth",
        iconURL: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/d6/8f/47/d68f4742-5a10-b375-2114-0f840bd49ec1/AppIcon-1781539049-0-0-1x_U007emarketing-0-8-0-85-220.png/512x512bb.jpg",
        sortOrder: 10,
        system: true
    )

    static let freeFireMaxFallback = HMOnlineGame(
        id: "freefiremax",
        name: "Free Fire MAX",
        bundleID: "com.dts.freefiremax",
        iconURL: "https://is1-ssl.mzstatic.com/image/thumb/Purple211/v4/ee/47/52/ee4752e4-9bc4-84c8-6d5c-8b9f2e8a1dfb/AppIcon-1724846612-1x_U007emarketing-0-7-0-85-220-0.png/512x512bb.jpg",
        sortOrder: 20,
        system: true
    )
}

@MainActor
final class HMOnlineAppsViewModel: ObservableObject {
    private static let apiURL = "https://miniapp.shopaccvt.site/proxy/api.php"

    @Published private(set) var games: [HMOnlineGame] = [
        .freeFireFallback,
        .freeFireMaxFallback
    ]
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var loaded = false

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task { await reload() }
    }

    func reload() async {
        guard var components = URLComponents(string: Self.apiURL) else { return }
        components.queryItems = [URLQueryItem(name: "build_id", value: HMBuildIdentity.id)]
        guard let url = components.url else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FFFeatureError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                if let payload = try? JSONDecoder().decode(FFServerErrorPayload.self, from: data) {
                    throw FFServerAccessError(code: payload.code ?? "server_error", message: payload.message ?? "Máy chủ từ chối yêu cầu.")
                }
                throw FFFeatureError.serverStatus(http.statusCode)
            }
            let decoded = try JSONDecoder().decode(FFRemoteResponse.self, from: data)
            var result: [HMOnlineGame] = []
            for (key, remote) in decoded.games {
                guard let bundleID = remote.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleID.isEmpty else { continue }
                let name = remote.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(HMOnlineGame(
                    id: key,
                    name: (name?.isEmpty == false ? name! : key),
                    bundleID: bundleID,
                    iconURL: remote.iconURL ?? "",
                    sortOrder: remote.sortOrder ?? 100,
                    system: remote.system ?? false
                ))
            }
            result.sort {
                if $0.sortOrder == $1.sortOrder { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                return $0.sortOrder < $1.sortOrder
            }
            if !result.isEmpty { games = result }
        } catch {
            errorMessage = error.localizedDescription
            if games.isEmpty { games = [.freeFireFallback, .freeFireMaxFallback] }
        }
    }
}

private enum HMHomeDestination: Hashable {
    case game(HMOnlineGame)
    case patch
}

struct ContentView: View {
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appsModel = HMOnlineAppsViewModel()
    @State private var path: [HMHomeDestination] = []

    private let accent = Color(red: 1.0, green: 0.72, blue: 0.05)
    private let card = Color(red: 0.075, green: 0.075, blue: 0.082)
    private let cardBorder = Color.white.opacity(0.085)

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 22) {
                        header
                        hero
                        appSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 34)
                }
                .refreshable { await appsModel.reload() }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: HMHomeDestination.self) { destination in
                switch destination {
                case .game(let game):
                    if game.id == "freefire" {
                        FreeFireFeaturesView(lockedGame: .freeFire)
                            .navigationTitle(game.name)
                            .navigationBarTitleDisplayMode(.inline)
                    } else if game.id == "freefiremax" {
                        FreeFireFeaturesView(lockedGame: .freeFireMax)
                            .navigationTitle(game.name)
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        HMOnlineGameFeaturesView(game: game)
                            .navigationTitle(game.name)
                            .navigationBarTitleDisplayMode(.inline)
                    }
                case .patch:
                    PatchProjectsView()
                        .navigationTitle("Patch")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .tint(accent)
        .preferredColorScheme(.dark)
        .onAppear {
            appsModel.loadIfNeeded()
            HMOnlineExpiryCoordinator.shared.sceneDidBecomeActive()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                HMOnlineExpiryCoordinator.shared.sceneDidBecomeActive()
            case .background:
                HMOnlineExpiryCoordinator.shared.sceneDidEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil { path = [.patch] }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { path = [.patch] }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill").font(.system(size: 12, weight: .bold))
                    Text("HM").font(.system(size: 28, weight: .black, design: .rounded))
                }
                .foregroundStyle(accent)
                Text("GAMING")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(2.4)
                    .foregroundStyle(Color.white.opacity(0.62))
            }
            Spacer()
            Button { Task { await appsModel.reload() } } label: {
                Circle()
                    .fill(card)
                    .frame(width: 44, height: 44)
                    .overlay {
                        if appsModel.isLoading {
                            ProgressView().tint(accent).scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                    }
                    .overlay(Circle().stroke(cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 54)
    }

    private var hero: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.085, blue: 0.035), Color(red: 0.055, green: 0.055, blue: 0.06), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
            GeometryReader { proxy in
                Circle().fill(accent.opacity(0.15)).frame(width: 190, height: 190).blur(radius: 8).offset(x: proxy.size.width - 130, y: -58)
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 92, weight: .black))
                    .foregroundStyle(accent.opacity(0.80))
                    .rotationEffect(.degrees(-8))
                    .offset(x: proxy.size.width - 122, y: 50)
            }
            .clipped()
            VStack(alignment: .leading, spacing: 7) {
                Text("ỨNG DỤNG").font(.system(size: 31, weight: .black, design: .rounded)).foregroundStyle(.white)
                Text("HM GAME CENTER").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(1.8).foregroundStyle(accent)
                Text("Các ô bên dưới được đồng bộ trực tiếp từ Admin.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .padding(22)
        }
        .frame(height: 168)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(accent.opacity(0.24), lineWidth: 1))
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ỨNG DỤNG TRÊN MÁY")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(appsModel.games.count) ứng dụng")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.42))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 18)], spacing: 22) {
                ForEach(appsModel.games) { game in appIcon(game) }
                patchIcon
            }
        }
    }

    private func appIcon(_ game: HMOnlineGame) -> some View {
        Button { path.append(.game(game)) } label: {
            VStack(spacing: 9) {
                AsyncImage(url: URL(string: game.iconURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        ZStack {
                            LinearGradient(colors: [accent.opacity(0.28), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(accent)
                        }
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

                Text(game.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 100)
            }
        }
        .buttonStyle(.plain)
    }

    private var patchIcon: some View {
        Button { path.append(.patch) } label: {
            VStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [accent.opacity(0.26), Color.white.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 84, height: 84)
                    .overlay {
                        Image(systemName: "shippingbox.fill")
                            .font(.system(size: 31, weight: .bold))
                            .foregroundStyle(accent)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                Text("Patch")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Generic online game feature page

struct HMOnlineActiveRecord: Codable, Identifiable, Hashable {
    let gameKey: String
    let bundleID: String
    let featureID: String
    let name: String
    let destinationPath: String
    let originalSHA256: String?
    var id: String { "\(gameKey):\(featureID)" }
}


// MARK: - Online app server authorization / automatic restore coordinator

extension Notification.Name {
    static let hmOnlineExpiryStateDidChange = Notification.Name("hmGaming.onlineExpiryStateDidChange")
}

@MainActor
final class HMOnlineExpiryCoordinator {
    static let shared = HMOnlineExpiryCoordinator()
    static let backgroundTaskIdentifier = "com.apple.mobile.MobileHouseArrest.hmexpiry"

    private let activeKey = "hmGaming.onlineGameActiveRecords.v1"
    private let keyInfoKey = "hmGaming.onlineGameKeyInfo.v1"
    private let seenRunningBundlesKey = "hmGaming.onlineGameSeenRunningBundles.v1"

    private var registeredBackgroundTask = false
    private var processingIDs: Set<String> = []
    private var shortBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var shortBackgroundWatcher: Task<Void, Never>?
    private var lastServerAuthorizationCheck: Date = .distantPast
    private let serverAuthorizationCheckInterval: TimeInterval = 15

    private init() {}

    /// Register once during app launch. iOS may run this task later while the app is suspended.
    func registerBackgroundTask() {
        guard !registeredBackgroundTask else { return }
        registeredBackgroundTask = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self.handleBackgroundProcessingTask(processingTask)
            }
        }
    }

    /// Layer 1: every time HM GAMING becomes active, immediately scan all online-app sessions.
    func sceneDidBecomeActive() {
        stopShortBackgroundWatcher()
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        Task { @MainActor in
            // Server is the source of truth for deleted, disabled AND expired keys.
            await restoreRevokedFeaturesIfNeeded(force: true)
            await restoreFeaturesForClosedOnlineAppsIfNeeded()
            scheduleNextBackgroundProcessingTask()
        }
    }

    /// Layer 2: when HM GAMING enters multitasking/background, use the remaining execution window
    /// and ask iOS for a BGProcessing wake-up. The stored expiry is only a scheduling hint;
    /// the server still confirms authorization before any restore.
    func sceneDidEnterBackground() {
        scheduleNextBackgroundProcessingTask()
        startShortBackgroundWatcher()
    }


    /// Server authorization watcher for generic online apps only.
    /// This is the single source of truth for automatic shutdown: deleted, locked,
    /// expired, scope-revoked keys, or disabled/removed features all return
    /// authorized=false. Only then do we silently restore the original file.
    func restoreRevokedFeaturesIfNeeded(force: Bool = false) async {
        let now = Date()
        if !force, now.timeIntervalSince(lastServerAuthorizationCheck) < serverAuthorizationCheckInterval {
            return
        }
        lastServerAuthorizationCheck = now

        let records = readActiveRecords()
        for record in records {
            let op = operationKey(record)
            guard !processingIDs.contains(op),
                  let token = FFAccessTokenStore.load(gameKey: record.gameKey, featureID: record.featureID) else {
                continue
            }

            let status: FFSessionAuthorizationStatus
            do {
                status = try await FFAccessClient.authorizationStatus(
                    gameKey: record.gameKey,
                    featureID: record.featureID,
                    accessToken: token
                )
            } catch {
                // Network/server failure is UNKNOWN, never a revocation. Keep the feature active.
                continue
            }

            guard !status.authorized else { continue }

            processingIDs.insert(op)
            defer { processingIDs.remove(op) }

            do {
                let grant = try await FFAccessClient.restore(
                    gameKey: record.gameKey,
                    featureID: record.featureID,
                    accessToken: token
                )
                _ = try await FFFeatureInstaller.install(
                    remoteURL: grant.downloadURL,
                    expectedSHA256: grant.downloadSHA256 ?? record.originalSHA256,
                    bundleID: record.bundleID,
                    destinationPath: grant.destinationPath
                )

                var latestRecords = readActiveRecords()
                latestRecords.removeAll { $0.id == record.id }
                persistActiveRecords(latestRecords)

                var latestInfo = readKeyInfo()
                latestInfo.removeValue(forKey: op)
                persistKeyInfo(latestInfo)

                FFAccessTokenStore.delete(gameKey: record.gameKey, featureID: record.featureID)
                NotificationCenter.default.post(name: .hmOnlineExpiryStateDidChange, object: record.id)
                // Silent by design: revoked keys do not produce a toast/popup.
            } catch {
                // Keep the active session so the next status check can retry the restore.
                // Silent by design.
            }
        }
    }

    /// Close-watch applies only to the generic online-app record store. The built-in
    /// Free Fire / Free Fire MAX pages use FFActiveRecord and therefore never enter here.
    /// A bundle must first be observed running. Only a later trusted `not running` probe
    /// can trigger restore, preventing a missing process API from causing false disables.
    func restoreFeaturesForClosedOnlineAppsIfNeeded() async {
        var records = readActiveRecords()
        guard !records.isEmpty else {
            persistSeenRunningBundles([])
            return
        }

        let activeBundles = Set(records.map(\.bundleID))
        var seenRunning = readSeenRunningBundles().intersection(activeBundles)

        for bundleID in activeBundles {
            let state = applicationProcessStateForBundleID(bundleID)
            if state == 1 {
                seenRunning.insert(bundleID)
                continue
            }
            // -1 means the process probe was unavailable. Never interpret it as closed.
            guard state == 0, seenRunning.contains(bundleID) else { continue }

            let bundleRecords = records.filter { $0.bundleID == bundleID }
            for record in bundleRecords {
                let op = operationKey(record)
                guard !processingIDs.contains(op),
                      let token = FFAccessTokenStore.load(gameKey: record.gameKey, featureID: record.featureID) else {
                    continue
                }

                processingIDs.insert(op)
                defer { processingIDs.remove(op) }
                do {
                    let grant = try await FFAccessClient.restore(
                        gameKey: record.gameKey,
                        featureID: record.featureID,
                        accessToken: token
                    )
                    _ = try await FFFeatureInstaller.install(
                        remoteURL: grant.downloadURL,
                        expectedSHA256: grant.downloadSHA256 ?? record.originalSHA256,
                        bundleID: record.bundleID,
                        destinationPath: grant.destinationPath
                    )

                    var latestRecords = readActiveRecords()
                    latestRecords.removeAll { $0.id == record.id }
                    persistActiveRecords(latestRecords)
                    records = latestRecords
                    NotificationCenter.default.post(name: .hmOnlineExpiryStateDidChange, object: record.id)
                    // Deliberately keep the still-valid key token/access info, matching manual OFF.
                    // Silent by design: no toast, alert or notification.
                } catch {
                    // Keep the active record + seen-running marker so a later check can retry.
                    // Silent by design.
                }
            }

            if !records.contains(where: { $0.bundleID == bundleID }) {
                seenRunning.remove(bundleID)
            }
        }

        seenRunning.formIntersection(Set(readActiveRecords().map(\.bundleID)))
        persistSeenRunningBundles(seenRunning)
    }

    private func readSeenRunningBundles() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: seenRunningBundlesKey) ?? [])
    }

    private func persistSeenRunningBundles(_ bundles: Set<String>) {
        UserDefaults.standard.set(Array(bundles).sorted(), forKey: seenRunningBundlesKey)
    }

    func nextExpiryDate() -> Date? {
        let records = readActiveRecords()
        let activeIDs = Set(records.map { operationKey($0) })
        let info = readKeyInfo()
        return activeIDs.compactMap { key -> Date? in
            guard let item = info[key] else { return nil }
            return keyExpiryDate(item.expiresAt)
        }.min()
    }

    private func startShortBackgroundWatcher() {
        stopShortBackgroundWatcher()

        shortBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "HMOnlineKeyExpiry") { [weak self] in
            Task { @MainActor in
                self?.stopShortBackgroundWatcher()
            }
        }

        shortBackgroundWatcher = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.stopShortBackgroundWatcher() }

            while !Task.isCancelled {
                await self.restoreRevokedFeaturesIfNeeded()
                await self.restoreFeaturesForClosedOnlineAppsIfNeeded()
                guard !Task.isCancelled, !self.readActiveRecords().isEmpty else { return }

                let expiryDelay = self.nextExpiryDate().map { max(0.25, $0.timeIntervalSinceNow) } ?? 3.0
                let seconds = min(expiryDelay, 3.0)
                let nanos = UInt64(max(seconds, 0.25) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    private func stopShortBackgroundWatcher() {
        shortBackgroundWatcher?.cancel()
        shortBackgroundWatcher = nil
        if shortBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(shortBackgroundTask)
            shortBackgroundTask = .invalid
        }
    }

    private func scheduleNextBackgroundProcessingTask() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        guard !readActiveRecords().isEmpty else { return }

        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        let closeCheckFallback = Date().addingTimeInterval(15 * 60)
        request.earliestBeginDate = nextExpiryDate().map { min(max($0, Date().addingTimeInterval(1)), closeCheckFallback) } ?? closeCheckFallback
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundProcessingTask(_ task: BGProcessingTask) {
        let work = Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            await self.restoreRevokedFeaturesIfNeeded(force: true)
            await self.restoreFeaturesForClosedOnlineAppsIfNeeded()
            self.scheduleNextBackgroundProcessingTask()
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    private func operationKey(_ record: HMOnlineActiveRecord) -> String {
        "\(record.gameKey):\(record.featureID)"
    }

    private func keyExpiryDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let normal = ISO8601DateFormatter()
        if let date = normal.date(from: value) { return date }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
    }

    private func readActiveRecords() -> [HMOnlineActiveRecord] {
        guard let data = UserDefaults.standard.data(forKey: activeKey),
              let records = try? JSONDecoder().decode([HMOnlineActiveRecord].self, from: data) else {
            return []
        }
        return records
    }

    private func persistActiveRecords(_ records: [HMOnlineActiveRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: activeKey)
        }
    }

    private func readKeyInfo() -> [String: FFKeyAccessInfo] {
        guard let data = UserDefaults.standard.data(forKey: keyInfoKey),
              let info = try? JSONDecoder().decode([String: FFKeyAccessInfo].self, from: data) else {
            return [:]
        }
        return info
    }

    private func persistKeyInfo(_ info: [String: FFKeyAccessInfo]) {
        if let data = try? JSONEncoder().encode(info) {
            UserDefaults.standard.set(data, forKey: keyInfoKey)
        }
    }
}

struct HMOnlineKeyPrompt: Identifiable, Hashable {
    let feature: FFRemoteFeature
    let game: HMOnlineGame
    var id: String { "\(game.id):\(feature.id)" }
}

@MainActor
final class HMOnlineGameFeatureViewModel: ObservableObject {
    private static let apiURL = "https://miniapp.shopaccvt.site/proxy/api.php"
    private static let activeKey = "hmGaming.onlineGameActiveRecords.v1"
    private static let keyInfoKey = "hmGaming.onlineGameKeyInfo.v1"

    let game: HMOnlineGame
    @Published private(set) var features: [FFRemoteFeature] = []
    @Published private(set) var activeRecords: [HMOnlineActiveRecord] = []
    @Published private(set) var keyAccessInfo: [String: FFKeyAccessInfo] = [:]
    @Published private(set) var busyIDs: Set<String> = []
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var keyPrompt: HMOnlineKeyPrompt?

    private var loaded = false

    init(game: HMOnlineGame) {
        self.game = game
        activeRecords = Self.readActiveRecords()
        keyAccessInfo = Self.readKeyInfo()
    }

    func syncPersistedExpiryState() {
        activeRecords = Self.readActiveRecords()
        keyAccessInfo = Self.readKeyInfo()
    }

    var visibleFeatures: [FFRemoteFeature] {
        features.filter { feature in
            feature.enabled || isActive(feature)
        }
    }

    var orphanedActiveRecords: [HMOnlineActiveRecord] {
        let ids = Set(features.map(\.id))
        return activeRecords.filter { $0.gameKey == game.id && !ids.contains($0.featureID) }
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        Task { await reload() }
    }

    func reload() async {
        guard var components = URLComponents(string: Self.apiURL) else { return }
        components.queryItems = [URLQueryItem(name: "build_id", value: HMBuildIdentity.id)]
        guard let url = components.url else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FFFeatureError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                if let payload = try? JSONDecoder().decode(FFServerErrorPayload.self, from: data) {
                    throw FFServerAccessError(code: payload.code ?? "server_error", message: payload.message ?? "Máy chủ từ chối yêu cầu.")
                }
                throw FFFeatureError.serverStatus(http.statusCode)
            }
            let decoded = try JSONDecoder().decode(FFRemoteResponse.self, from: data)
            guard let remote = decoded.games[game.id] else {
                throw FFServerAccessError(code: "game_not_found", message: "Ứng dụng này không còn trên máy chủ.")
            }
            features = remote.features
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isActive(_ feature: FFRemoteFeature) -> Bool {
        activeRecords.contains { $0.gameKey == game.id && $0.featureID == feature.id }
    }

    func isBusy(_ feature: FFRemoteFeature) -> Bool { busyIDs.contains(operationKey(feature.id)) }

    func setFeature(_ feature: FFRemoteFeature, enabled: Bool) {
        let op = operationKey(feature.id)
        guard !busyIDs.contains(op) else { return }
        if enabled {
            guard feature.enabled else { notice = "Chức năng đang bị tắt trên máy chủ."; return }
            if let token = FFAccessTokenStore.load(gameKey: game.id, featureID: feature.id) {
                busyIDs.insert(op)
                Task {
                    defer { busyIDs.remove(op) }
                    do {
                        try await activate(feature, key: nil, accessToken: token)
                    } catch let auth as FFServerAccessError where auth.shouldAskForKey {
                        FFAccessTokenStore.delete(gameKey: game.id, featureID: feature.id)
                        keyAccessInfo.removeValue(forKey: op)
                        persistKeyInfo()
                        keyPrompt = HMOnlineKeyPrompt(feature: feature, game: game)
                    } catch { notice = error.localizedDescription }
                }
            } else {
                keyPrompt = HMOnlineKeyPrompt(feature: feature, game: game)
            }
        } else {
            restore(feature)
        }
    }

    func activateWithKey(_ key: String, prompt: HMOnlineKeyPrompt) async -> String? {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Vui lòng nhập key." }
        let op = operationKey(prompt.feature.id)
        guard !busyIDs.contains(op) else { return "Chức năng đang được xử lý." }
        busyIDs.insert(op)
        defer { busyIDs.remove(op) }
        do {
            try await activate(prompt.feature, key: value, accessToken: nil)
            keyPrompt = nil
            return nil
        } catch { return error.localizedDescription }
    }

    func dismissKeyPrompt() { keyPrompt = nil }

    private func activate(_ feature: FFRemoteFeature, key: String?, accessToken: String?) async throws {
        let grant = try await FFAccessClient.activate(feature: feature, gameKey: game.id, key: key, accessToken: accessToken)
        if let token = grant.accessToken, !token.isEmpty {
            FFAccessTokenStore.store(token, gameKey: game.id, featureID: feature.id)
        }
        keyAccessInfo[operationKey(feature.id)] = FFKeyAccessInfo(
            expiresAt: grant.keyExpiresAt ?? "",
            maxDevices: max(1, grant.maxDevices ?? 1),
            deviceCount: max(0, grant.deviceCount ?? 0)
        )
        persistKeyInfo()

        _ = try await FFFeatureInstaller.install(
            remoteURL: grant.downloadURL,
            expectedSHA256: grant.downloadSHA256 ?? feature.activeSHA256,
            bundleID: game.bundleID,
            destinationPath: grant.destinationPath
        )

        activeRecords.removeAll { $0.gameKey == game.id && $0.destinationPath == grant.destinationPath && $0.featureID != feature.id }
        activeRecords.removeAll { $0.gameKey == game.id && $0.featureID == feature.id }
        activeRecords.append(HMOnlineActiveRecord(
            gameKey: game.id,
            bundleID: game.bundleID,
            featureID: feature.id,
            name: feature.name,
            destinationPath: grant.destinationPath,
            originalSHA256: feature.originalSHA256
        ))
        persistActiveRecords()
        notice = "Đã bật \(feature.name) thành công"
    }

    private func restore(_ feature: FFRemoteFeature) {
        let op = operationKey(feature.id)
        guard let record = activeRecords.first(where: { $0.gameKey == game.id && $0.featureID == feature.id }) else { return }
        guard let token = FFAccessTokenStore.load(gameKey: game.id, featureID: feature.id) else {
            notice = "Không tìm thấy phiên khôi phục của chức năng này."
            return
        }
        busyIDs.insert(op)
        Task {
            defer { busyIDs.remove(op) }
            do {
                try await performRestore(record, token: token)
                notice = "Đã tắt \(feature.name) thành công"
            } catch { notice = error.localizedDescription }
        }
    }

    func restoreOrphan(_ record: HMOnlineActiveRecord) {
        let op = operationKey(record.featureID)
        guard !busyIDs.contains(op) else { return }
        guard let token = FFAccessTokenStore.load(gameKey: game.id, featureID: record.featureID) else {
            notice = "Không tìm thấy phiên khôi phục cho \(record.name)."
            return
        }
        busyIDs.insert(op)
        Task {
            defer { busyIDs.remove(op) }
            do {
                try await performRestore(record, token: token)
                notice = "Đã khôi phục \(record.name)."
            } catch { notice = error.localizedDescription }
        }
    }

    private func performRestore(_ record: HMOnlineActiveRecord, token: String) async throws {
        let grant = try await FFAccessClient.restore(gameKey: record.gameKey, featureID: record.featureID, accessToken: token)
        _ = try await FFFeatureInstaller.install(
            remoteURL: grant.downloadURL,
            expectedSHA256: grant.downloadSHA256 ?? record.originalSHA256,
            bundleID: record.bundleID,
            destinationPath: grant.destinationPath
        )
        activeRecords.removeAll { $0.id == record.id }
        persistActiveRecords()
    }


    func keyStatusText(_ feature: FFRemoteFeature) -> String? {
        guard let info = keyAccessInfo[operationKey(feature.id)] else { return nil }
        let device = "\(info.deviceCount)/\(info.maxDevices) thiết bị"
        guard !info.expiresAt.isEmpty else { return "Key: Vô hạn • \(device)" }
        let fmt = ISO8601DateFormatter()
        guard let expiry = fmt.date(from: info.expiresAt) else { return "Key còn hạn • \(device)" }
        let remaining = expiry.timeIntervalSinceNow
        guard remaining > 0 else { return "Key đã hết hạn" }
        let mins = Int(remaining / 60)
        let days = mins / 1440
        let hours = (mins % 1440) / 60
        let time = days > 0 ? "\(days) ngày \(hours) giờ" : (hours > 0 ? "\(hours) giờ" : "\(max(1, mins)) phút")
        return "Còn hạn: \(time) • \(device)"
    }

    private func operationKey(_ featureID: String) -> String { "\(game.id):\(featureID)" }

    private func persistActiveRecords() {
        if let data = try? JSONEncoder().encode(activeRecords) { UserDefaults.standard.set(data, forKey: Self.activeKey) }
    }
    private static func readActiveRecords() -> [HMOnlineActiveRecord] {
        guard let data = UserDefaults.standard.data(forKey: activeKey), let records = try? JSONDecoder().decode([HMOnlineActiveRecord].self, from: data) else { return [] }
        return records
    }
    private func persistKeyInfo() {
        if let data = try? JSONEncoder().encode(keyAccessInfo) { UserDefaults.standard.set(data, forKey: Self.keyInfoKey) }
    }
    private static func readKeyInfo() -> [String: FFKeyAccessInfo] {
        guard let data = UserDefaults.standard.data(forKey: keyInfoKey), let info = try? JSONDecoder().decode([String: FFKeyAccessInfo].self, from: data) else { return [:] }
        return info
    }
}

struct HMOnlineGameFeaturesView: View {
    let game: HMOnlineGame
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: HMOnlineGameFeatureViewModel
    @State private var showGetKey = false
    @State private var noticeDismissTask: Task<Void, Never>?
    @State private var expiryWatchTask: Task<Void, Never>?

    private let accent = Color(red: 1.0, green: 0.72, blue: 0.05)
    private let card = Color(red: 0.075, green: 0.075, blue: 0.082)
    private let border = Color.white.opacity(0.085)

    init(game: HMOnlineGame) {
        self.game = game
        _model = StateObject(wrappedValue: HMOnlineGameFeatureViewModel(game: game))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    gameHeader
                    getKeyButton
                    featureHeader
                    content
                    statusCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 35)
            }
            .refreshable { await model.reload() }

            if let notice = model.notice {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(notice).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color(red: 0.075, green: 0.075, blue: 0.082).opacity(0.98), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.green.opacity(0.35), lineWidth: 1))
                .padding(.horizontal, 18).padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(100)
            }
        }
        .sheet(item: $model.keyPrompt) { prompt in
            HMOnlineKeyEntrySheet(model: model, prompt: prompt)
        }
        .sheet(isPresented: $showGetKey) {
            if let url = getKeyURL { FFGetKeySafariView(url: url).ignoresSafeArea() }
        }
        .onAppear {
            model.loadIfNeeded()
            startExpiryWatcher()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.syncPersistedExpiryState()
                startExpiryWatcher()
            } else {
                expiryWatchTask?.cancel()
                expiryWatchTask = nil
            }
        }
        .onChange(of: model.activeRecords) { _ in
            if scenePhase == .active { startExpiryWatcher() }
        }
        .onChange(of: model.keyAccessInfo) { _ in
            if scenePhase == .active { startExpiryWatcher() }
        }
        .onChange(of: model.notice) { value in
            noticeDismissTask?.cancel()
            guard value != nil else { return }
            noticeDismissTask = Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { model.notice = nil } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hmOnlineExpiryStateDidChange)) { _ in
            model.syncPersistedExpiryState()
            if scenePhase == .active { startExpiryWatcher() }
        }
        .onDisappear {
            noticeDismissTask?.cancel()
            expiryWatchTask?.cancel()
            expiryWatchTask = nil
        }
    }

    private func startExpiryWatcher() {
        expiryWatchTask?.cancel()
        expiryWatchTask = Task { @MainActor in
            while !Task.isCancelled {
                // Expiry/revocation is confirmed by the server; the device clock never
                // decides to restore a feature on its own.
                await HMOnlineExpiryCoordinator.shared.restoreRevokedFeaturesIfNeeded()
                model.syncPersistedExpiryState()
                guard !Task.isCancelled else { return }

                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private var gameHeader: some View {
        HStack(spacing: 14) {
            AsyncImage(url: URL(string: game.iconURL)) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default:
                    ZStack { Color.white.opacity(0.06); Image(systemName: "gamecontroller.fill").foregroundStyle(accent) }
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(border, lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                Text(game.name.uppercased()).font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(.white).lineLimit(2)
                Text("FEATURE CENTER").font(.system(size: 10.5, weight: .heavy)).tracking(1.5).foregroundStyle(accent)
                Text(game.bundleID).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Color.white.opacity(0.38)).lineLimit(1)
            }
            Spacer()
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(border, lineWidth: 1))
    }

    private var getKeyButton: some View {
        Button { showGetKey = true } label: {
            HStack {
                Image(systemName: "key.fill")
                Text("NHẬN KEY").font(.system(size: 14, weight: .heavy, design: .rounded))
                Spacer()
                Image(systemName: "arrow.up.right")
            }
            .foregroundStyle(.black).padding(.horizontal, 16).frame(height: 52).background(accent, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    private var getKeyURL: URL? {
        guard var c = URLComponents(string: "https://miniapp.shopaccvt.site/proxy/getkey.php") else { return nil }
        c.queryItems = [URLQueryItem(name: "game", value: game.id)]
        return c.url
    }

    private var featureHeader: some View {
        HStack {
            Image(systemName: "bolt.fill").foregroundStyle(accent)
            Text("CHỨC NĂNG").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            Spacer()
            Button { Task { await model.reload() } } label: {
                if model.isLoading { ProgressView().tint(accent) } else { Image(systemName: "arrow.clockwise").foregroundStyle(accent) }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 3)
    }

    @ViewBuilder private var content: some View {
        if let error = model.errorMessage {
            stateCard(error)
        } else if model.isLoading && model.visibleFeatures.isEmpty {
            stateCard("Đang tải danh sách chức năng…")
        } else if model.visibleFeatures.isEmpty && model.orphanedActiveRecords.isEmpty {
            stateCard("Chưa có chức năng. Thêm trên Admin rồi làm mới.")
        } else {
            ForEach(model.visibleFeatures) { feature in featureCard(feature) }
            ForEach(model.orphanedActiveRecords) { record in orphanCard(record) }
        }
    }

    private func stateCard(_ text: String) -> some View {
        HStack { Image(systemName: "server.rack").foregroundStyle(accent); Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.62)); Spacer() }
            .padding(16).background(card, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(border, lineWidth: 1))
    }

    private func featureCard(_ feature: FFRemoteFeature) -> some View {
        let active = model.isActive(feature)
        let busy = model.isBusy(feature)
        return HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 14).fill(accent.opacity(active ? 0.18 : 0.09)).frame(width: 50, height: 50).overlay {
                Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .bold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(feature.name.uppercased()).font(.system(size: 14.5, weight: .heavy, design: .rounded)).foregroundStyle(.white).lineLimit(1)
                Text(model.keyStatusText(feature) ?? (active ? "Đang kích hoạt" : "Chạm công tắc để bật"))
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(active ? accent : Color.white.opacity(0.47)).lineLimit(1)
                if let note = feature.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(note).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.40)).lineLimit(2)
                }
            }
            Spacer()
            if busy { ProgressView().tint(accent).frame(width: 50) }
            else {
                Toggle("", isOn: Binding(get: { model.isActive(feature) }, set: { model.setFeature(feature, enabled: $0) }))
                    .labelsHidden().tint(accent).disabled(!feature.enabled && !active)
            }
        }
        .padding(14).background(card, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(active ? accent.opacity(0.35) : border, lineWidth: 1))
    }

    private func orphanCard(_ record: HMOnlineActiveRecord) -> some View {
        HStack {
            Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading) {
                Text(record.name).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                Text("Chức năng không còn trên server").font(.system(size: 10.5)).foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
            Button { model.restoreOrphan(record) } label: { Image(systemName: "arrow.uturn.backward").foregroundStyle(.black).frame(width: 36, height: 36).background(accent, in: Circle()) }
        }
        .padding(14).background(card, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(border, lineWidth: 1))
    }

    private var statusCard: some View {
        let count = model.activeRecords.filter { $0.gameKey == game.id }.count
        return HStack {
            Image(systemName: count > 0 ? "checkmark.shield.fill" : "shield.fill").foregroundStyle(accent)
            Text(count > 0 ? "Đang bật \(count) chức năng." : "Chưa kích hoạt chức năng nào.")
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color.white.opacity(0.62))
            Spacer()
        }
        .padding(15).background(card, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(border, lineWidth: 1))
    }
}

struct HMOnlineKeyEntrySheet: View {
    @ObservedObject var model: HMOnlineGameFeatureViewModel
    let prompt: HMOnlineKeyPrompt
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var errorMessage: String?
    @State private var submitting = false
    private let accent = Color(red: 1.0, green: 0.72, blue: 0.05)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 17) {
                    Text(prompt.feature.name.uppercased()).font(.system(size: 23, weight: .black, design: .rounded)).foregroundStyle(.white)
                    Text("Nhập key cho \(prompt.game.name). Server sẽ kiểm tra hạn và số thiết bị trước khi tải file.")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Color.white.opacity(0.53))
                    SecureField("Nhập key", text: $key)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .padding(.horizontal, 14).frame(height: 50)
                        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
                    if let errorMessage { Text(errorMessage).font(.system(size: 12, weight: .semibold)).foregroundStyle(.red) }
                    Button {
                        guard !submitting else { return }
                        submitting = true
                        Task {
                            let error = await model.activateWithKey(key, prompt: prompt)
                            await MainActor.run {
                                submitting = false
                                if let error { errorMessage = error } else { dismiss() }
                            }
                        }
                    } label: {
                        HStack { if submitting { ProgressView().tint(.black) }; Text(submitting ? "Đang xác thực…" : "Xác thực & bật") }
                            .font(.system(size: 14, weight: .heavy)).foregroundStyle(.black).frame(maxWidth: .infinity).frame(height: 50).background(accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Xác thực key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Đóng") { model.dismissKeyPrompt(); dismiss() }.foregroundStyle(accent) } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }
}
