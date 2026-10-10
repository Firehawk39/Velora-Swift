import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct VeloraBackup: Codable {
    var version: Int = 1
    var exportedAt: Date = Date()
    var serverUrl: String
    var onlineServerUrl: String
    var username: String
    var connectionMode: Int
    var fanartApiKey: String?
    var downloadIndex: IntegrityManager.DownloadIndex?
}

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    private init() {}

    func createBackup() -> URL? {
        let serverUrl = UserDefaults.standard.string(forKey: "velora_server_url") ?? ""
        let onlineServerUrl = UserDefaults.standard.string(forKey: "velora_online_server_url") ?? ""
        let username = UserDefaults.standard.string(forKey: "velora_username") ?? ""
        let connectionMode = UserDefaults.standard.integer(forKey: "velora_connection_mode")
        let rawKey = UserDefaults.standard.string(forKey: "velora_fanart_api_key")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fanartKey = (rawKey != nil && !rawKey!.isEmpty) ? rawKey : nil

        let downloadIndex = IntegrityManager.shared.getIndex()

        let backup = VeloraBackup(
            version: 1,
            exportedAt: Date(),
            serverUrl: serverUrl,
            onlineServerUrl: onlineServerUrl,
            username: username,
            connectionMode: connectionMode,
            fanartApiKey: fanartKey,
            downloadIndex: downloadIndex
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(backup) else { return nil }

        let tempDir = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let fileUrl = tempDir.appendingPathComponent("Velora_Backup_\(timestamp).json")

        do {
            try data.write(to: fileUrl, options: .atomic)
            return fileUrl
        } catch {
            AppLogger.shared.log("Failed to write backup file: \(error.localizedDescription)", level: .error)
            return nil
        }
    }

    func restoreBackup(from fileUrl: URL) -> Result<String, Error> {
        let accessing = fileUrl.startAccessingSecurityScopedResource()
        defer {
            if accessing { fileUrl.stopAccessingSecurityScopedResource() }
        }

        do {
            let data = try Data(contentsOf: fileUrl)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let backup = try decoder.decode(VeloraBackup.self, from: data)

            // 1. Restore user preferences
            if !backup.serverUrl.isEmpty {
                UserDefaults.standard.set(backup.serverUrl, forKey: "velora_server_url")
            }
            if !backup.onlineServerUrl.isEmpty {
                UserDefaults.standard.set(backup.onlineServerUrl, forKey: "velora_online_server_url")
            }
            if !backup.username.isEmpty {
                UserDefaults.standard.set(backup.username, forKey: "velora_username")
            }
            UserDefaults.standard.set(backup.connectionMode, forKey: "velora_connection_mode")

            if let fanartKey = backup.fanartApiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !fanartKey.isEmpty {
                UserDefaults.standard.set(fanartKey, forKey: "velora_fanart_api_key")
            } else {
                UserDefaults.standard.removeObject(forKey: "velora_fanart_api_key")
            }

            // 2. Sync to Keychain
            let bundle = VeloraCredentialsBundle(
                serverUrl: backup.serverUrl,
                onlineServerUrl: backup.onlineServerUrl,
                username: backup.username,
                connectionMode: backup.connectionMode
            )
            if let bundleData = try? JSONEncoder().encode(bundle) {
                KeychainHelper.shared.save(bundleData, service: "velora-credentials", account: "default")
            }

            // 3. Restore Download Index if present
            var restoredTracksCount = 0
            if let index = backup.downloadIndex {
                IntegrityManager.shared.restoreIndex(index)
                restoredTracksCount = index.tracks.count
            }

            // 4. Update network state
            NetworkMonitor.shared.evaluateConnectionState()

            let fanartNote = (backup.fanartApiKey != nil && !backup.fanartApiKey!.isEmpty) ? "Fanart API key included" : "no Fanart key"
            let summary = "Restored configuration for \(backup.username) (\(restoredTracksCount) indexed downloads, \(fanartNote))."
            AppLogger.shared.log("✅ Backup restored: \(summary)", level: .info)
            return .success(summary)
        } catch {
            AppLogger.shared.log("❌ Backup restoration failed: \(error.localizedDescription)", level: .error)
            return .failure(error)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
