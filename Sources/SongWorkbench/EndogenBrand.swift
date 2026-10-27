// Endogen brand tokens v1.0. Source: Brand Guidelines (2026-10-26). Copied from the
// endogen-brand skill (tokens/EndogenBrand.swift) and run through this repo's swift-format;
// values unchanged.
// Drop into a SwiftUI target. Space Grotesk and JetBrains Mono must be bundled
// (UIAppFonts / ATSApplicationFontsPath) for the custom fonts; otherwise the system font is used.
import SwiftUI

extension Color {
    public enum Endogen {
        public static let night = Color(hex: 0x0D1117)
        public static let scope = Color(hex: 0x070A0E)
        public static let graticule = Color(hex: 0x273345)
        public static let grid = Color(hex: 0x1C2532)
        public static let axis = Color(hex: 0x34415A)
        public static let innerRing = Color(hex: 0x22493A)
        public static let frost = Color(hex: 0xE8EDF2)
        public static let text = Color(hex: 0xC3CCD6)
        public static let mist = Color(hex: 0x8B96A3)
        public static let phosphor = Color(hex: 0x33FF33)
        public static let amber = Color(hex: 0xFFB547)
        public static let paper = Color(hex: 0xF5F7F9)
        public static let ink = Color(hex: 0x0D1117)
        public static let slate = Color(hex: 0x5B6573)
        public static let deepPhosphor = Color(hex: 0x0E7A24)
    }

    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

extension Font {
    public enum Endogen {
        public static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .custom("Space Grotesk", size: size).weight(weight)
        }
        public static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .custom("JetBrains Mono", size: size).weight(weight)
        }
        public static let display = sans(72, .bold)
        public static let h1 = sans(48, .bold)
        public static let h2 = sans(32, .bold)
        public static let h3 = sans(24, .medium)
        public static let body = sans(17)
        public static let small = sans(14)
        public static let label = mono(13, .medium)  // use .textCase(.uppercase) and .tracking(1.3)
        public static let readout = mono(18)
    }
}
