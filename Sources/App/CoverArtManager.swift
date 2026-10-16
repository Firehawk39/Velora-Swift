import Foundation
import UIKit

// MARK: - Centralized Unified Cover Art Pipeline
/// Manages high-performance in-memory caching, disk persistence, request deduplication,
/// and queue lookahead prefetching for album artwork across streaming and offline playback.
final class CoverArtManager: @unchecked Sendable {
    static let shared = CoverArtManager()

    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 120
        cache.totalCostLimit = 60 * 1024 * 1024 // 60 MB
        return cache
    }()

    private let lock = NSLock()
    private var inFlightTasks: [String: Task<UIImage?, Never>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Synchronous Quick Lookup (0ms Memory / Disk Check)

    func cachedImage(for artId: String) -> UIImage? {
        let cleanId = extractArtId(from: artId)
        guard !cleanId.isEmpty else { return nil }

        // 1. In-memory check (0ms)
        if let memoryHit = memoryCache.object(forKey: cleanId as NSString) {
            return memoryHit
        }

        // 2. Disk cache check (0ms)
        let fm = FileManager.default
        let coverDir = VeloraStorage.coverArt
        for ext in ["jpg", "jpeg", "png", "webp"] {
            let localUrl = coverDir.appendingPathComponent("\(cleanId).\(ext)")
            if fm.fileExists(atPath: localUrl.path),
               let data = try? Data(contentsOf: localUrl),
               let image = UIImage(data: data) {
                let cost = data.count
                memoryCache.setObject(image, forKey: cleanId as NSString, cost: cost)
                return image
            }
        }
        return nil
    }

    // MARK: - Async Load with Deduplication

    func loadArtwork(url: URL?, artId: String, albumId: String? = nil) async -> UIImage? {
        let cleanId = extractArtId(from: artId)
        guard !cleanId.isEmpty else { return nil }

        // Quick check
        if let hit = cachedImage(for: cleanId) {
            return hit
        }

        guard let url = url else { return nil }

        // Local file fast path
        if url.isFileURL {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                memoryCache.setObject(image, forKey: cleanId as NSString, cost: data.count)
                if let aid = albumId {
                    let cleanAid = extractArtId(from: aid)
                    if !cleanAid.isEmpty && cleanAid != cleanId {
                        memoryCache.setObject(image, forKey: cleanAid as NSString, cost: data.count)
                    }
                }
                return image
            }
            return nil
        }

        // Deduplicate in-flight requests
        let cleanAid = albumId.map { extractArtId(from: $0) }
        let (task, _) = getOrCreateInFlightTask(cleanId: cleanId, url: url, cleanAid: cleanAid)
        let result = await task.value
        removeInFlightTask(cleanId: cleanId)
        return result
    }

    private func getOrCreateInFlightTask(cleanId: String, url: URL, cleanAid: String? = nil) -> (Task<UIImage?, Never>, Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlightTasks[cleanId] {
            return (existing, false)
        }
        let task = Task<UIImage?, Never> {
            await self.fetchImage(url: url, cleanId: cleanId, cleanAid: cleanAid)
        }
        inFlightTasks[cleanId] = task
        return (task, true)
    }

    private func removeInFlightTask(cleanId: String) {
        lock.lock()
        defer { lock.unlock() }
        inFlightTasks.removeValue(forKey: cleanId)
    }

    private func fetchImage(url: URL, cleanId: String, cleanAid: String? = nil) async -> UIImage? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  data.count > 100,
                  let image = UIImage(data: data) else {
                return nil
            }

            // Cache STRICTLY in RAM for streaming — DO NOT save to persistent device disk storage
            memoryCache.setObject(image, forKey: cleanId as NSString, cost: data.count)
            if let aid = cleanAid, !aid.isEmpty, aid != cleanId {
                memoryCache.setObject(image, forKey: aid as NSString, cost: data.count)
            }
            return image
        } catch {
            return nil
        }
    }

    // MARK: - Queue Lookahead Prefetching

    func preloadArtwork(for tracks: [Track], count: Int = 6) {
        guard !tracks.isEmpty else { return }
        let subset = Array(tracks.prefix(count))

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            for track in subset {
                let rawArtId = track.coverArt ?? track.albumId ?? track.id.components(separatedBy: ".").first ?? track.id
                let cleanId = extractArtId(from: rawArtId)
                guard !cleanId.isEmpty else { continue }

                // Skip if already in memory or on disk
                if self.cachedImage(for: cleanId) != nil {
                    continue
                }

                if let url = track.coverArtUrl {
                    _ = await self.loadArtwork(url: url, artId: cleanId, albumId: track.albumId)
                }
            }
        }
    }
}
