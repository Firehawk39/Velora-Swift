import SwiftUI
import CoreText
import Foundation

@main
struct VeloraApp: App {
    init() {
        registerCustomFonts()
        setupURLCache()
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
            print("❌ Failed to find or load Stardom-Regular.otf in main or module bundle.")
            return
        }
        
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterGraphicsFont(font, &error) {
            print("❌ Error registering font: \(error!.takeUnretainedValue())")
        } else {
            print("✅ Successfully registered Stardom font")
            
            // Debug: Print all available fonts
            #if canImport(UIKit)
            print("--- Registered Font Families ---")
            for family in UIFont.familyNames {
                if family.contains("Stardom") || family.hasPrefix("S") {
                    print("Found font family: \(family)")
                    for name in UIFont.fontNames(forFamilyName: family) {
                        print("   - Font name: \(name)")
                    }
                }
            }
            print("--------------------------------")
            #endif
        }
    }

}
