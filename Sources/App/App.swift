import SwiftUI
import CoreText
import Foundation

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == "com.velora.downloads" {
            PlaybackManager.sharedBackgroundCompletion = completionHandler
        }
    }
}

@main
struct VeloraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Migrate data from Documents/ to Application Support/VeloraData/ (one-time)
        VeloraStorage.migrateFromDocumentsIfNeeded()
        VeloraStorage.ensureDirectories()

        // Purge any NO_LYRICS sentinel files written during bad-network conditions
        // so that tracks can be retried on next play without nuking real lyrics.
        Self.purgePoisonedLyricsCache()

        // Purge corrupt "NA" image markers left by previous app versions
        Self.purgePoisonedImageCache()

        registerCustomFonts()
        setupURLCache()
    }


    private static func purgePoisonedLyricsCache() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: VeloraStorage.lyrics, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let file as URL in enumerator {
            guard let isDir = try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, !isDir else { continue }
            if let text = try? String(contentsOf: file, encoding: .utf8),
               text.trimmingCharacters(in: .whitespacesAndNewlines) == "NO_LYRICS" {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Purge corrupt "NA" poison image files written by previous app versions on download failure.
    /// These 2-byte text files pass file-existence checks but cannot be rendered as images,
    /// causing permanently missing artwork even after Repair Sync completes.
    private static func purgePoisonedImageCache() {
        let fm = FileManager.default
        let dirs = [VeloraStorage.coverArt, VeloraStorage.artistPortraits]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files {
                if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]),
                   let size = attrs.fileSize, size < 100 {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }


    private func setupURLCache() {
        // Configure a robust cache for album arts and metadata
        // 50 MB in-memory, 500 MB on-disk
        let cache = URLCache(memoryCapacity: 50 * 1024 * 1024,
                             diskCapacity: 500 * 1024 * 1024,
                             diskPath: "velora_media_cache")
        URLCache.shared = cache
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private func registerCustomFonts() {
        // Find the font URL - searching main bundle and common sub-bundles
        let fontName = "Stardom-Regular"
        let fontExt = "otf"

        var url: URL? = nil

        url = Bundle.main.url(forResource: fontName, withExtension: fontExt)

        if url == nil {
            // In some environments, resources are in a separate .bundle folder
            let possibleBundleNames = ["AppModule_AppModule", "AppModule", "Velora"]
            for name in possibleBundleNames {
                if let bundleUrl = Bundle.main.url(forResource: name, withExtension: "bundle"),
                   let bundle = Bundle(url: bundleUrl) {
                    url = bundle.url(forResource: fontName, withExtension: fontExt)
                    if url != nil { break }
                }
            }
        }

        guard let fontUrl = url,
              let fontDataProvider = CGDataProvider(url: fontUrl as CFURL),
              let font = CGFont(fontDataProvider) else {
            AppLogger.shared.log("❌ Failed to find or load Stardom-Regular.otf in main or module bundle.", level: .error)
            return
        }

        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(font, &error) {
            AppLogger.shared.log("❌ Error registering font: \(error!.takeUnretainedValue())", level: .error)
        }
    }
}
