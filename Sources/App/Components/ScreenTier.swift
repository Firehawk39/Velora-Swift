import SwiftUI
import UIKit

// MARK: - Screen Tier
public enum ScreenTier {
    case tiny, compact, regular, large, huge
    public static var current: ScreenTier {
        let w = UIScreen.main.bounds.width
        if w <= 320 { return .tiny } // iPhone SE 1st Gen
        if w < 414 { return .compact } // Standard iPhone / mini
        if w < 768 { return .regular } // Plus/Max iPhones
        if w < 1024 { return .large } // 10.25" Displays / standard iPads
        return .huge // iPad Pro 12.9"
    }
    public static var isSE: Bool { current == .tiny }
    public static var isPhone: Bool { UIScreen.main.bounds.width < 768 }
    public static var isHuge: Bool { current == .huge }
}
