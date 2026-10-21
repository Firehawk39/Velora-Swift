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
        // Initialize device power monitor to track charging state immediately
        _ = DevicePowerMonitor.shared

        // Migrate data from Documents/ to Application Support/VeloraData/ (one-time)
        VeloraStorage.migrateFromDocumentsIfNeeded()
        VeloraStorage.ensureDirectories()

        // Purge corrupt "NA" image markers left by previous app versions
        Self.purgePoisonedImageCache()

        registerCustomFonts()
        setupURLCache()

        // Start the native AI Powerhouse MCP Server
        VeloraMCPServer.shared.start()
    }

    /// Purge corrupt "NA" poison image files and sub-spec downloads written on failure.
    /// These files pass file-existence checks but cannot be rendered as images,
    /// causing missing artwork and wasted disk storage.
    private static func purgePoisonedImageCache() {
        let fm = FileManager.default
        let dirs = [VeloraStorage.coverArt, VeloraStorage.artistPortraits, VeloraStorage.backdrops, VeloraStorage.clearLogos]
        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for file in files {
                if let attrs = try? file.resourceValues(forKeys: [.fileSizeKey]), let size = attrs.fileSize {
                    let minSize = (dir == VeloraStorage.backdrops) ? 10_000 : 1_000
                    if size < minSize {
                        try? fm.removeItem(at: file)
                    } else if let data = try? Data(contentsOf: file), UIImage(data: data) == nil {
                        try? fm.removeItem(at: file)
                    }
                }
            }
        }
        FanartManager.shared.wipeNegativeFanartCaches()
    }


    private func setupURLCache() {
        // Dynamic Hardware Profiling for RAM
        let physicalMemory = ProcessInfo.processInfo.physicalMemory // in bytes
        // 50 MB minimum, up to 10% of physical memory (capped at 500MB max)
        let maxMemoryCache = min(Int(Double(physicalMemory) * 0.10), 500 * 1024 * 1024)
        let memoryCacheSize = max(50 * 1024 * 1024, maxMemoryCache)

        // Set diskCapacity to 0: Velora maintains its own persistent, content-addressable
        // file system in Application Support/VeloraData (VeloraStorage).
        // Foundation URLCache disk writing causes massive duplicate cache bloat (up to 500MB)
        // while streaming. Disabling URLCache disk writes saves massive storage with zero impact on streaming.
        let cache = URLCache(memoryCapacity: memoryCacheSize,
                             diskCapacity: 0,
                             diskPath: nil)
        URLCache.shared = cache

        // Evict legacy Foundation disk cache folder if it was created by older builds
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let legacyCache = cachesDir.appendingPathComponent("velora_media_cache")
            try? FileManager.default.removeItem(at: legacyCache)
        }
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
            if let errorRef = error?.takeUnretainedValue() {
                let nsError = errorRef as Error as NSError
                if nsError.code != 105 && nsError.code != 305 { // 105/305 = kCTFontManagerErrorAlreadyRegistered
                    AppLogger.shared.log("❌ Error registering font: \(errorRef)", level: .error)
                }
            }
        }
    }
}
