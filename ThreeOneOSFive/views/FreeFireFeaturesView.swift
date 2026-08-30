import SwiftUI
import Foundation
import CryptoKit
import Security
import UIKit

// MARK: - Fixed game scope

enum FFGameKind: String, CaseIterable, Identifiable, Codable {
    case freeFire = "freefire"
    case freeFireMax = "freefiremax"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeFire: return "Free Fire"
        case .freeFireMax: return "Free Fire MAX"
        }
    }

    // The remote server is intentionally not allowed to choose a bundle ID.
    // This module can only write inside these two app containers.
    var bundleID: String {
        switch self {
        case .freeFire: return "com.dts.freefireth"
        case .freeFireMax: return "com.dts.freefiremax"
        }
    }
}

struct FFRemoteResponse: Decodable {
    let version: Int?
    let games: [String: FFRemoteGame]
}

struct FFRemoteGame: Decodable {
    let name: String?
    let features: [FFRemoteFeature]
}

struct FFRemoteFeature: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let enabled: Bool
    let destinationPath: String
    let activeSHA256: String?
    let originalSHA256: String?
    let requiresKey: Bool?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case destinationPath = "destination_path"
        case activeSHA256 = "active_sha256"
        case originalSHA256 = "original_sha256"
        case requiresKey = "requires_key"
        case updatedAt = "updated_at"
    }
}

struct FFActiveRecord: Codable, Identifiable, Hashable {
    let game: FFGameKind
    let featureID: String
    let name: String
    let destinationPath: String
    let originalSHA256: String?

    var id: String { "\(game.rawValue):\(featureID)" }
}

struct FFAccessGrant: Decodable {
    let ok: Bool
    let accessToken: String?
    let downloadURL: String
    let downloadSHA256: String?
    let expiresIn: Int?
    let destinationPath: String

    enum CodingKeys: String, CodingKey {
        case ok
        case accessToken = "access_token"
        case downloadURL = "download_url"
        case downloadSHA256 = "download_sha256"
        case expiresIn = "expires_in"
        case destinationPath = "destination_path"
    }
}

struct FFServerErrorPayload: Decodable {
    let ok: Bool?
    let code: String?
    let message: String?
}

struct FFKeyPrompt: Identifiable, Hashable {
    let feature: FFRemoteFeature
    let game: FFGameKind
    var id: String { "\(game.rawValue):\(feature.id)" }
}

// MARK: - Errors / installer

enum FFFeatureError: Error, LocalizedError {
    case serverNotConfigured
    case invalidServerURL
    case invalidResponse
    case serverStatus(Int)
    case serverMessage(String)
    case invalidDownloadURL
    case downloadFailed
    case checksumMismatch
    case containerUnavailable(String)
    case invalidDestinationPath
    case targetMissing(String)
    case targetIsDirectory
    case symbolicLinkUnsupported
    case installFailed

    var errorDescription: String? {
        switch self {
        case .serverNotConfigured:
            return "Chưa cấu hình địa chỉ API của máy chủ."
        case .invalidServerURL:
            return "Địa chỉ máy chủ không hợp lệ. Hãy dùng URL HTTPS trỏ tới api.php."
        case .invalidResponse:
            return "Máy chủ trả về dữ liệu không hợp lệ."
        case .serverStatus(let code):
            return "Máy chủ trả về lỗi HTTP \(code)."
        case .serverMessage(let message):
            return message
        case .invalidDownloadURL:
            return "URL file trên máy chủ không hợp lệ hoặc không dùng HTTPS."
        case .downloadFailed:
            return "Không thể tải file từ máy chủ."
        case .checksumMismatch:
            return "File tải xuống không khớp SHA-256. Đã hủy cài đặt."
        case .containerUnavailable(let bundleID):
            return "Không truy cập được data của \(bundleID). Hãy kiểm tra quyền truy cập của HM GAMING."
        case .invalidDestinationPath:
            return "Đường dẫn đích không hợp lệ. Đường dẫn phải tương đối bên trong data game."
        case .targetMissing(let path):
            return "Không tìm thấy file đích: \(path)"
        case .targetIsDirectory:
            return "Đường dẫn đích đang trỏ tới một thư mục, không phải file."
        case .symbolicLinkUnsupported:
            return "Không hỗ trợ đường dẫn có symbolic link."
        case .installFailed:
            return "Không thể thay file vào data game."
        }
    }
}

enum FFFeatureInstaller {
    private static let hashChunkSize = 1_024 * 1_024

    static func install(
        remoteURL: String,
        expectedSHA256: String?,
        game: FFGameKind,
        destinationPath: String
    ) async throws -> Int64 {
        guard let url = URL(string: remoteURL),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            throw FFFeatureError.invalidDownloadURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration)

        let downloadedURL: URL
        do {
            let (tempURL, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse else {
                throw FFFeatureError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                throw FFFeatureError.serverStatus(http.statusCode)
            }
            downloadedURL = tempURL
        } catch let error as FFFeatureError {
            throw error
        } catch {
            throw FFFeatureError.downloadFailed
        }

        if let expectedSHA256,
           !expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let actual = try sha256(of: downloadedURL)
            guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
                throw FFFeatureError.checksumMismatch
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let containerPath = ContainerStore.resolveAppContainerPath(bundleID: game.bundleID) else {
                        throw FFFeatureError.containerUnavailable(game.bundleID)
                    }

                    // Mirror the Files tab access grant before attempting a write.
                    var activationError: NSString?
                    let mcmHandle = MCMActivateContainer(2, game.bundleID, false, &activationError)
                    if mcmHandle < 0 {
                        _ = ContainerStore.grantContainerAccess(containerPath)
                    }

                    let targetURL = try validatedTargetURL(
                        containerPath: containerPath,
                        relativePath: destinationPath
                    )

                    let result = try FileReplacementService.replace(
                        target: targetURL,
                        with: downloadedURL
                    )
                    continuation.resume(returning: result.byteCount)
                } catch let error as FFFeatureError {
                    continuation.resume(throwing: error)
                } catch let error as FileReplacementError {
                    switch error {
                    case .targetMissing:
                        continuation.resume(throwing: FFFeatureError.targetMissing(destinationPath))
                    case .targetIsDirectory:
                        continuation.resume(throwing: FFFeatureError.targetIsDirectory)
                    case .symbolicLinkUnsupported:
                        continuation.resume(throwing: FFFeatureError.symbolicLinkUnsupported)
                    default:
                        continuation.resume(throwing: FFFeatureError.installFailed)
                    }
                } catch {
                    continuation.resume(throwing: FFFeatureError.installFailed)
                }
            }
        }
    }

    private static func validatedTargetURL(
        containerPath: String,
        relativePath rawPath: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let relativePath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty,
              relativePath.count <= 2_048,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw FFFeatureError.invalidDestinationPath
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              components.count <= 128,
              !components.contains("."),
              !components.contains("..") else {
            throw FFFeatureError.invalidDestinationPath
        }

        let rootURL = URL(fileURLWithPath: containerPath, isDirectory: true).standardizedFileURL
        let targetURL = rootURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path.hasPrefix(rootPrefix) else {
            throw FFFeatureError.invalidDestinationPath
        }

        // Reject any existing symlink component so a server path cannot escape the game container.
        var cursor = rootURL
        for component in components {
            cursor.appendPathComponent(component)
            if fileManager.fileExists(atPath: cursor.path) {
                let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw FFFeatureError.symbolicLinkUnsupported
                }
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw FFFeatureError.targetMissing(relativePath)
        }
        guard !isDirectory.boolValue else {
            throw FFFeatureError.targetIsDirectory
        }
        return targetURL
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: hashChunkSize), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Secure feature access

struct FFServerAccessError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }

    var shouldAskForKey: Bool {
        ["key_required", "invalid_key", "key_disabled", "key_expired", "device_limit", "invalid_session"].contains(code)
    }
}

enum FFAccessTokenStore {
    private static let service = "com.apple.mobile.MobileHouseArrest.ff-feature-access"

    private static func account(game: FFGameKind, featureID: String) -> String {
        "\(game.rawValue):\(featureID)"
    }

    static func store(_ token: String, game: FFGameKind, featureID: String) {
        guard let data = token.data(using: .utf8), !data.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(game: game, featureID: featureID)
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var item = query
            attrs.forEach { item[$0.key] = $0.value }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func load(game: FFGameKind, featureID: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(game: game, featureID: featureID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(game: FFGameKind, featureID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(game: game, featureID: featureID)
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}

enum FFDeviceIdentity {
    private static let fallbackKey = "hmGaming.ffDeviceID.v1"

    static var value: String {
        if let id = UIDevice.current.identifierForVendor?.uuidString, !id.isEmpty {
            return id
        }
        if let existing = UserDefaults.standard.string(forKey: fallbackKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: fallbackKey)
        return generated
    }
}

enum FFAccessClient {
    private static let accessURL = "https://miniapp.shopaccvt.site/proxy/access.php"

    static func activate(
        feature: FFRemoteFeature,
        game: FFGameKind,
        key: String? = nil,
        accessToken: String? = nil
    ) async throws -> FFAccessGrant {
        var body: [String: Any] = [
            "action": "activate",
            "game": game.rawValue,
            "feature_id": feature.id,
            "device_id": FFDeviceIdentity.value
        ]
        if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["key"] = key
        }
        if let accessToken, !accessToken.isEmpty {
            body["access_token"] = accessToken
        }
        return try await request(body)
    }

    static func restore(record: FFActiveRecord, accessToken: String) async throws -> FFAccessGrant {
        try await request([
            "action": "restore",
            "game": record.game.rawValue,
            "feature_id": record.featureID,
            "device_id": FFDeviceIdentity.value,
            "access_token": accessToken
        ])
    }

    private static func request(_ body: [String: Any]) async throws -> FFAccessGrant {
        guard let url = URL(string: accessURL) else { throw FFFeatureError.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FFFeatureError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            if let payload = try? JSONDecoder().decode(FFServerErrorPayload.self, from: data) {
                throw FFServerAccessError(code: payload.code ?? "server_error", message: payload.message ?? "Máy chủ từ chối yêu cầu.")
            }
            throw FFFeatureError.serverStatus(http.statusCode)
        }
        return try JSONDecoder().decode(FFAccessGrant.self, from: data)
    }
}

// MARK: - View model

@MainActor
final class FreeFireFeatureViewModel: ObservableObject {
    private static let serverAPIURL = "https://miniapp.shopaccvt.site/proxy/api.php"
    private static let activeRecordsKey = "ffFeatureActiveRecords.v2"

    @Published var selectedGame: FFGameKind = .freeFire
    @Published private(set) var remoteGames: [String: FFRemoteGame] = [:]
    @Published private(set) var activeRecords: [FFActiveRecord] = []
    @Published private(set) var busyIDs: Set<String> = []
    @Published var isLoading = false
    @Published var notice: String?
    @Published var serverConfigurationError: String?
    @Published var keyPrompt: FFKeyPrompt?

    private var hasLoaded = false

    init() {
        activeRecords = Self.readActiveRecords()
    }

    var visibleFeatures: [FFRemoteFeature] {
        let all = remoteGames[selectedGame.rawValue]?.features ?? []
        return all.filter { $0.enabled || activeRecord(forFeatureID: $0.id, game: selectedGame) != nil }
    }

    var orphanedActiveRecords: [FFActiveRecord] {
        let known = Set((remoteGames[selectedGame.rawValue]?.features ?? []).map(\.id))
        return activeRecords.filter { $0.game == selectedGame && !known.contains($0.featureID) }
    }

    var hasConfiguredServer: Bool { true }

    func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        Task { await reload() }
    }

    func reload() async {
        guard let apiURL = validatedAPIURL(from: Self.serverAPIURL) else {
            remoteGames = [:]
            serverConfigurationError = FFFeatureError.invalidServerURL.localizedDescription
            return
        }

        isLoading = true
        serverConfigurationError = nil
        defer { isLoading = false }

        do {
            var request = URLRequest(url: apiURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FFFeatureError.invalidResponse }
            guard (200...299).contains(http.statusCode) else { throw FFFeatureError.serverStatus(http.statusCode) }
            let decoded = try JSONDecoder().decode(FFRemoteResponse.self, from: data)
            var accepted: [String: FFRemoteGame] = [:]
            for game in FFGameKind.allCases {
                if let remote = decoded.games[game.rawValue] { accepted[game.rawValue] = remote }
            }
            remoteGames = accepted
        } catch let error as FFFeatureError {
            serverConfigurationError = error.localizedDescription
        } catch {
            serverConfigurationError = "Không tải được danh sách chức năng: \(error.localizedDescription)"
        }
    }

    func isActive(_ feature: FFRemoteFeature, game: FFGameKind? = nil) -> Bool {
        activeRecord(forFeatureID: feature.id, game: game ?? selectedGame) != nil
    }

    func isBusy(_ feature: FFRemoteFeature, game: FFGameKind? = nil) -> Bool {
        busyIDs.contains(operationKey(featureID: feature.id, game: game ?? selectedGame))
    }

    func setFeature(_ feature: FFRemoteFeature, enabled: Bool) {
        let game = selectedGame
        let operation = operationKey(featureID: feature.id, game: game)
        guard !busyIDs.contains(operation) else { return }

        if enabled {
            guard feature.enabled else {
                notice = "Chức năng này đang bị tắt trên máy chủ."
                return
            }
            if let token = FFAccessTokenStore.load(game: game, featureID: feature.id) {
                busyIDs.insert(operation)
                Task {
                    defer { busyIDs.remove(operation) }
                    do {
                        try await performActivation(feature: feature, game: game, key: nil, accessToken: token)
                    } catch let auth as FFServerAccessError where auth.shouldAskForKey {
                        FFAccessTokenStore.delete(game: game, featureID: feature.id)
                        keyPrompt = FFKeyPrompt(feature: feature, game: game)
                    } catch {
                        notice = error.localizedDescription
                    }
                }
            } else {
                keyPrompt = FFKeyPrompt(feature: feature, game: game)
            }
        } else {
            restore(feature: feature, game: game)
        }
    }

    func activateWithKey(_ key: String, prompt: FFKeyPrompt) async -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Vui lòng nhập key." }
        let operation = operationKey(featureID: prompt.feature.id, game: prompt.game)
        guard !busyIDs.contains(operation) else { return "Chức năng đang được xử lý." }
        busyIDs.insert(operation)
        defer { busyIDs.remove(operation) }
        do {
            try await performActivation(feature: prompt.feature, game: prompt.game, key: trimmed, accessToken: nil)
            keyPrompt = nil
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func dismissKeyPrompt() { keyPrompt = nil }

    private func performActivation(feature: FFRemoteFeature, game: FFGameKind, key: String?, accessToken: String?) async throws {
        let grant = try await FFAccessClient.activate(feature: feature, game: game, key: key, accessToken: accessToken)
        guard grant.ok else { throw FFFeatureError.invalidResponse }
        if let newToken = grant.accessToken, !newToken.isEmpty {
            FFAccessTokenStore.store(newToken, game: game, featureID: feature.id)
        }

        _ = try await FFFeatureInstaller.install(
            remoteURL: grant.downloadURL,
            expectedSHA256: grant.downloadSHA256 ?? feature.activeSHA256,
            game: game,
            destinationPath: grant.destinationPath
        )

        activeRecords.removeAll {
            $0.game == game &&
            $0.destinationPath == grant.destinationPath &&
            $0.featureID != feature.id
        }
        activeRecords.removeAll { $0.game == game && $0.featureID == feature.id }
        activeRecords.append(FFActiveRecord(
            game: game,
            featureID: feature.id,
            name: feature.name,
            destinationPath: grant.destinationPath,
            originalSHA256: feature.originalSHA256
        ))
        persistActiveRecords()
        notice = "Đã bật \(feature.name) thành công"
    }

    private func restore(feature: FFRemoteFeature, game: FFGameKind) {
        let operation = operationKey(featureID: feature.id, game: game)
        guard !busyIDs.contains(operation) else { return }
        guard let record = activeRecord(forFeatureID: feature.id, game: game) else { return }
        guard let token = FFAccessTokenStore.load(game: game, featureID: feature.id) else {
            notice = "Không tìm thấy phiên khôi phục của chức năng này."
            return
        }
        busyIDs.insert(operation)
        Task {
            defer { busyIDs.remove(operation) }
            do {
                try await performRestore(record: record, accessToken: token)
                notice = "Đã tắt \(feature.name) và khôi phục file gốc"
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    func restoreOrphan(_ record: FFActiveRecord) {
        let operation = operationKey(featureID: record.featureID, game: record.game)
        guard !busyIDs.contains(operation) else { return }
        guard let token = FFAccessTokenStore.load(game: record.game, featureID: record.featureID) else {
            notice = "Không tìm thấy phiên khôi phục cho \(record.name)."
            return
        }
        busyIDs.insert(operation)
        Task {
            defer { busyIDs.remove(operation) }
            do {
                try await performRestore(record: record, accessToken: token)
                notice = "Đã khôi phục file gốc cho \(record.name)."
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func performRestore(record: FFActiveRecord, accessToken: String) async throws {
        let grant = try await FFAccessClient.restore(record: record, accessToken: accessToken)
        _ = try await FFFeatureInstaller.install(
            remoteURL: grant.downloadURL,
            expectedSHA256: grant.downloadSHA256 ?? record.originalSHA256,
            game: record.game,
            destinationPath: grant.destinationPath
        )
        activeRecords.removeAll { $0.id == record.id }
        persistActiveRecords()
    }

    private func activeRecord(forFeatureID id: String, game: FFGameKind) -> FFActiveRecord? {
        activeRecords.first { $0.game == game && $0.featureID == id }
    }

    private func operationKey(featureID: String, game: FFGameKind) -> String {
        "\(game.rawValue):\(featureID)"
    }

    private func validatedAPIURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private func persistActiveRecords() {
        guard let data = try? JSONEncoder().encode(activeRecords) else { return }
        UserDefaults.standard.set(data, forKey: Self.activeRecordsKey)
    }

    private static func readActiveRecords() -> [FFActiveRecord] {
        guard let data = UserDefaults.standard.data(forKey: activeRecordsKey),
              let records = try? JSONDecoder().decode([FFActiveRecord].self, from: data) else { return [] }
        return records
    }
}

struct FFKeyEntrySheet: View {
    @ObservedObject var model: FreeFireFeatureViewModel
    let prompt: FFKeyPrompt

    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    private let accent = Color(red: 1.0, green: 0.72, blue: 0.05)

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("KEY RIÊNG")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .tracking(1.8)
                            .foregroundStyle(accent)
                        Text(prompt.feature.name.uppercased())
                            .font(.system(size: 25, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Key này chỉ dùng cho \(prompt.feature.name) trên \(prompt.game.title). Server sẽ kiểm tra hạn dùng và giới hạn thiết bị trước khi tải file.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SecureField("Nhập key chức năng", text: $key)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        guard !isSubmitting else { return }
                        isSubmitting = true
                        errorMessage = nil
                        Task {
                            let error = await model.activateWithKey(key, prompt: prompt)
                            await MainActor.run {
                                isSubmitting = false
                                if let error {
                                    errorMessage = error
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            if isSubmitting {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "checkmark.shield.fill")
                            }
                            Text(isSubmitting ? "Đang xác thực…" : "Xác thực & bật")
                        }
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)

                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(accent)
                        Text("Link file thật không được lưu trong app. Sau khi key hợp lệ, server cấp link tải tạm và app tự cài.")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.43))
                    }

                    Spacer()
                }
                .padding(20)
            }
            .navigationTitle("Xác thực key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Đóng") {
                        model.dismissKeyPrompt()
                        dismiss()
                    }
                    .foregroundStyle(accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - UI

struct FreeFireFeaturesView: View {
    @StateObject private var model = FreeFireFeatureViewModel()

    private let accent = Color(red: 1.0, green: 0.72, blue: 0.05)
    private let card = Color(red: 0.075, green: 0.075, blue: 0.082)
    private let cardBorder = Color.white.opacity(0.085)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    topHeader
                    heroBanner
                    gameSelector
                    featureHeader
                    mainContent
                    statusCard
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .refreshable { await model.reload() }
        }
        .alert(
            "Thông báo",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .sheet(item: $model.keyPrompt) { prompt in
            FFKeyEntrySheet(model: model, prompt: prompt)
        }
        .onAppear { model.loadIfNeeded() }
    }

    private var topHeader: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "crown.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("HM")
                        .font(.system(size: 27, weight: .black, design: .rounded))
                }
                .foregroundStyle(accent)

                Text("GAMING")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(2.3)
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            HStack {
                Circle()
                    .fill(card)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    .overlay(Circle().stroke(cardBorder, lineWidth: 1))

                Spacer()

                Color.clear
                    .frame(width: 44, height: 44)
            }
        }
        .frame(height: 54)
    }

    private var heroBanner: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.10, green: 0.085, blue: 0.035),
                            Color(red: 0.055, green: 0.055, blue: 0.06),
                            Color.black
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            GeometryReader { proxy in
                Circle()
                    .fill(accent.opacity(0.16))
                    .frame(width: 180, height: 180)
                    .blur(radius: 6)
                    .offset(x: proxy.size.width - 125, y: -48)

                Image(systemName: "flame.fill")
                    .font(.system(size: 104, weight: .black))
                    .foregroundStyle(accent.opacity(0.86))
                    .rotationEffect(.degrees(-8))
                    .offset(x: proxy.size.width - 110, y: 33)
            }
            .clipped()

            VStack(alignment: .leading, spacing: 7) {
                Text("FREE FIRE")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)

                Text("SERVER FEATURE PANEL")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(accent)

                Text("Chọn phiên bản game và bật chức năng bạn muốn sử dụng.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.58))
                    .frame(maxWidth: 230, alignment: .leading)
            }
            .padding(22)
        }
        .frame(height: 174)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(accent.opacity(0.24), lineWidth: 1)
        )
    }

    private var gameSelector: some View {
        HStack(spacing: 10) {
            ForEach(FFGameKind.allCases) { game in
                gameCard(game)
            }
        }
    }

    private func gameCard(_ game: FFGameKind) -> some View {
        let selected = model.selectedGame == game
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                model.selectedGame = game
            }
        } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(selected ? accent.opacity(0.16) : Color.white.opacity(0.055))
                    .frame(width: 48, height: 48)
                    .overlay {
                        Image(systemName: game == .freeFire ? "flame.fill" : "bolt.fill")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(selected ? accent : Color.white.opacity(0.70))
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(game == .freeFire ? "FREE FIRE" : "FF MAX")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(game == .freeFire ? "Garena Free Fire" : "Free Fire MAX")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? accent.opacity(0.95) : Color.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(selected ? accent.opacity(0.075) : card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(selected ? accent : cardBorder, lineWidth: selected ? 1.8 : 1)
            )
            .shadow(color: selected ? accent.opacity(0.15) : .clear, radius: 12)
        }
        .buttonStyle(.plain)
    }

    private var featureHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(accent)
            Text("CHỨC NĂNG")
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            Spacer()

            Button {
                Task { await model.reload() }
            } label: {
                HStack(spacing: 7) {
                    if model.isLoading {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Làm mới")
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(card, in: Capsule())
                .overlay(Capsule().stroke(cardBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(model.isLoading || !model.hasConfiguredServer)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var mainContent: some View {
        if let error = model.serverConfigurationError {
            serverStateCard(error)
        } else if model.isLoading && model.visibleFeatures.isEmpty {
            loadingCard
        } else if !model.hasConfiguredServer {
            serverStateCard("Chưa cấu hình máy chủ.")
        } else if model.visibleFeatures.isEmpty && model.orphanedActiveRecords.isEmpty {
            emptyCard
        } else {
            ForEach(model.visibleFeatures) { feature in
                featureCard(feature)
            }

            if !model.orphanedActiveRecords.isEmpty {
                orphanedSection
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 13) {
            ProgressView().tint(accent)
            Text("Đang tải danh sách chức năng…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.65))
            Spacer()
        }
        .padding(18)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardBorder, lineWidth: 1))
    }

    private func serverStateCard(_ text: String) -> some View {
        HStack(spacing: 14) {
            featureIcon(systemName: "server.rack", active: false)
            VStack(alignment: .leading, spacing: 5) {
                Text("MÁY CHỦ")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(16)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardBorder, lineWidth: 1))
    }

    private var emptyCard: some View {
        VStack(spacing: 11) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(accent)
            Text("Chưa có chức năng")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Text("Thêm chức năng trên trang Admin của server rồi bấm Làm mới.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.50))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardBorder, lineWidth: 1))
    }

    private func featureCard(_ feature: FFRemoteFeature) -> some View {
        let isActive = model.isActive(feature)
        let isBusy = model.isBusy(feature)
        let presentation = featurePresentation(for: feature.name)

        return HStack(spacing: 14) {
            featureIcon(systemName: presentation.icon, active: isActive)

            VStack(alignment: .leading, spacing: 5) {
                Text(feature.name.uppercased())
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(isActive ? "Đang kích hoạt" : "Key riêng • \(presentation.subtitle)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(isActive ? accent : Color.white.opacity(0.48))
                    .lineLimit(1)

                if !feature.enabled && isActive {
                    Text("Đã ẩn trên server • tắt để khôi phục")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isBusy {
                ProgressView()
                    .tint(accent)
                    .frame(width: 50, height: 32)
            } else {
                Toggle("", isOn: Binding(
                    get: { model.isActive(feature) },
                    set: { model.setFeature(feature, enabled: $0) }
                ))
                .labelsHidden()
                .tint(accent)
                .disabled(!feature.enabled && !isActive)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isActive ? accent.opacity(0.35) : cardBorder, lineWidth: 1)
        )
    }

    private func featureIcon(systemName: String, active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(accent.opacity(active ? 0.18 : 0.095))
            .frame(width: 50, height: 50)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(accent)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(accent.opacity(active ? 0.32 : 0.12), lineWidth: 1)
            )
    }

    private func featurePresentation(for rawName: String) -> (icon: String, subtitle: String) {
        let name = rawName.lowercased()
        if name.contains("esp") || name.contains("map") { return ("scope", "Chức năng hiển thị") }
        if name.contains("invi") || name.contains("vô hình") { return ("eye.slash.fill", "Chức năng nhân vật") }
        if name.contains("tele") { return ("figure.run", "Chức năng di chuyển") }
        if name.contains("ghost") || name.contains("xuyên") { return ("circle.dotted", "Chức năng tùy chỉnh") }
        if name.contains("freeze") || name.contains("đóng băng") { return ("snowflake", "Chức năng tùy chỉnh") }
        if name.contains("speed") || name.contains("tốc") { return ("gauge.with.dots.needle.67percent", "Chức năng tốc độ") }
        if name.contains("lag") || name.contains("ping") { return ("wifi", "Chức năng mạng") }
        if name.contains("aim") { return ("dot.scope", "Chức năng ngắm") }
        if name.contains("skin") || name.contains("avatar") { return ("person.crop.square.fill", "Tùy chỉnh tài nguyên") }
        return ("bolt.fill", "Chạm công tắc để bật/tắt")
    }

    private var orphanedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                Text("CẦN KHÔI PHỤC")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            ForEach(model.orphanedActiveRecords) { record in
                HStack(spacing: 13) {
                    featureIcon(systemName: "arrow.uturn.backward", active: false)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.name.uppercased())
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Chức năng không còn trên server")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.46))
                    }
                    Spacer()
                    Button {
                        model.restoreOrphan(record)
                    } label: {
                        if model.busyIDs.contains("\(record.game.rawValue):\(record.featureID)") {
                            ProgressView().tint(accent)
                        } else {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 14, weight: .bold))
                        }
                    }
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.black)
                    .background(accent, in: Circle())
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardBorder, lineWidth: 1))
            }
        }
    }

    private var statusCard: some View {
        let activeCount = model.activeRecords.filter { $0.game == model.selectedGame }.count
        return HStack(spacing: 13) {
            featureIcon(systemName: activeCount > 0 ? "checkmark.shield.fill" : "shield.fill", active: activeCount > 0)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("Trạng thái:")
                        .foregroundStyle(.white)
                    Text(activeCount > 0 ? "Đang kích hoạt" : "Chưa kích hoạt")
                        .foregroundStyle(activeCount > 0 ? accent : Color.white.opacity(0.55))
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))

                Text(activeCount > 0 ? "Đang bật \(activeCount) chức năng cho \(model.selectedGame.title)." : "Chọn một chức năng phía trên để bắt đầu.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
        }
        .padding(15)
        .background(card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(cardBorder, lineWidth: 1))
    }
}
