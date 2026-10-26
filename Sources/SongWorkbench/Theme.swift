import CoreText
import SwiftUI

struct SWRGBColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let white = SWRGBColor(red: 1, green: 1, blue: 1)

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255.0
        green = Double((hex >> 8) & 0xFF) / 255.0
        blue = Double(hex & 0xFF) / 255.0
    }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func contrastRatio(against other: SWRGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }
}

enum SWColorPalette {
    /// P31 Phosphor fill for prominent commands; its label is Night, not white (1.1:1 on
    /// phosphor). Kept as RGB so the contrast test can measure the pair.
    static let prominentControlTint = SWRGBColor(hex: 0x33FF33)
    static let prominentControlLabel = SWRGBColor(hex: 0x0D1117)
}

// MARK: - Color Palette
//
// SongWorkbench's tokens, now set in the Endogen brand (`EndogenBrand.swift`, guidelines v1.0,
// adopted 2026-10-26). Views keep the `sw*` names; each resolves to a `Color.Endogen` value, so
// the brand changes in one place. Dark only: the app forces `.preferredColorScheme(.dark)`, so
// the light tokens (Paper, Ink, Slate, Deep Phosphor) are unused.
//
// Saturation == importance. Chrome stays Night / Scope / Frost / Mist; P31 Phosphor marks the
// active selection and data highlights (~5%); Contact Amber is the one moving contact, the
// playback highlight. Stem lanes and the error coral are functional data colors outside the
// brand palette (Eric, 2026-10-26): five players need five distinct hues.

extension Color {
    /// App background / workspace canvas.
    static let swCanvas = Color.Endogen.night
    /// Panels / menus / cards: the brand's deep-panel ground.
    static let swSurface = Color.Endogen.scope
    /// A step forward of `swSurface`, for panels that should read as sitting in front of their
    /// neighbors (the Stem Mix console, so its controls have somewhere to cast a shadow onto).
    static let swSurfaceRaised = Color.Endogen.grid
    /// Primary accent: active selection / focus.
    static let swAccent = Color.Endogen.phosphor
    /// Filled command controls: phosphor with a Night label (14.0:1).
    static let swProminentControl = Color.Endogen.phosphor
    /// Label on `swProminentControl`.
    static let swProminentControlLabel = Color.Endogen.night
    /// Secondary accent: errors / alerts ONLY. A functional color outside the brand palette.
    static let swCoral = Color(hex: 0xFF6B6B)
    /// Data highlight: waveform peaks / data values.
    static let swMint = Color.Endogen.phosphor
    /// Active-playback highlight: the currently sung/played lyric words. The brand's one amber
    /// contact.
    static let swAmber = Color.Endogen.amber
    /// Violet — the guitar lane.
    static let swViolet = Color(hex: 0xCC5DE8)
    /// Teal — kept for callers outside the stem lanes.
    static let swTeal = Color(hex: 0x22B8CF)
    /// Piano's lane: teal sat 24° from the bass blue and read as the same player (Eric,
    /// 2026-10-08).
    static let swPink = Color(hex: 0xF06595)
    /// Bass lane blue. Was `swAccent` until the accent became phosphor (2026-10-26).
    static let swBassBlue = Color(hex: 0x339AF0)
    /// Vocals lane. Amber is the playback highlight now (one amber per screen), so the vocals
    /// moved to a green-teal clear of the bass blue (46°), the phosphor and the error coral
    /// (2026-10-26).
    static let swVocalTeal = Color(hex: 0x20C997)
    /// Primary text.
    static let swTextPrimary = Color.Endogen.frost
    /// Secondary / muted text.
    static let swTextSecondary = Color.Endogen.mist
    /// Borders and grid lines.
    static let swGraticule = Color.Endogen.graticule
}

extension StemKind {
    /// The lane color for this stem in the waveform panel. Single source of truth so the ChordPro
    /// per-line audio strip matches the stem it's drawn from (vocals = amber, guitar = violet,
    /// piano = teal, …) and the two can't drift apart.
    var laneColor: Color {
        switch self {
        case .vocals: .swVocalTeal
        case .drums: .swCoral
        case .bass: .swBassBlue
        case .guitar: .swViolet
        case .piano: .swPink
        case .other: .swTextSecondary
        }
    }
}

extension StemID {
    /// Waveform/mixer lane color for base stems and refined children (`drums.kick` → drums coral).
    var laneColor: Color {
        if let kind = legacyKind {
            return kind.laneColor
        }
        let root = rawValue.split(separator: ".").first.map(String.init) ?? rawValue
        return StemKind(rawValue: root)?.laneColor ?? .swTextSecondary
    }
}

// MARK: - Typography
//
// The brand faces, bundled under `Resources/Fonts` (SIL OFL) and registered at launch by
// `EndogenFonts.registerBundled()`. Sizes stay the app's own: the brand's type scale (body 17)
// is sized for the web and too large for this dense tool UI.

extension Font {
    /// Display / label font: Space Grotesk.
    static func swDisplay(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.Endogen.sans(size, weight)
    }

    /// Monospaced font for numeric / technical data and the column-aligned chart text:
    /// JetBrains Mono.
    static func swMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.Endogen.mono(size, weight)
    }
}

extension PlatformFont {
    /// JetBrains Mono for text MEASUREMENT, matching what `Font.swMono` draws. The chart sizes
    /// its columns from a measured advance; measuring SF Mono (9.27 pt per character at 15 pt)
    /// under JetBrains Mono glyphs (9.0 pt) would drift chords off their words.
    static func endogenMono(ofSize size: CGFloat, weight: PlatformFont.Weight = .regular)
        -> PlatformFont
    {
        #if os(macOS)
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: "JetBrains Mono",
                .traits: [NSFontDescriptor.TraitKey.weight: weight],
            ])
            if let font = NSFont(descriptor: descriptor, size: size),
                font.familyName == "JetBrains Mono"
            {
                return font
            }
        #else
            let descriptor = UIFontDescriptor(fontAttributes: [
                .family: "JetBrains Mono",
                .traits: [UIFontDescriptor.TraitKey.weight: weight],
            ])
            let font = UIFont(descriptor: descriptor, size: size)
            if font.familyName == "JetBrains Mono" { return font }
        #endif
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

enum EndogenFonts {
    /// Registers the bundled brand fonts for this process. Without them `Font.custom` silently
    /// falls back to the system font, which is proportional, and the ChordPro chart's columns
    /// stop lining up.
    static func registerBundled(bundle: Bundle = .main) {
        let urls = bundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls
        where url.lastPathComponent.hasPrefix("SpaceGrotesk")
            || url.lastPathComponent.hasPrefix("JetBrainsMono")
        {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Reusable Panel Modifiers

private struct SWSurfacePanel: ViewModifier {
    var cornerRadius: CGFloat
    var fill: Color = .swSurface

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
        }
    }
}

private struct SWGlassPanel: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

/// A quiet interactivity cue for analytical tool controls: a 1px accent
/// stroke that appears only on hover. Keep the control's fill monochrome.
private struct SWAccentHoverBorder: ViewModifier {
    var cornerRadius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.swAccent, lineWidth: 1)
                    .opacity(hovering ? 1 : 0)
            }
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Filled primary command: phosphor fill, Night label (WCAG AAA).
    func swProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color.swProminentControl)
            .foregroundStyle(Color.swProminentControlLabel)
    }

    /// Surface-grey panel: fill + subtle 1px white stroke. For cards,
    /// editor containers, sidebars, inspector panels. `fill` defaults to `swSurface`; pass
    /// `swSurfaceRaised` for a panel that should read slightly lighter than its neighbors.
    func swSurfacePanel(cornerRadius: CGFloat = 12, fill: Color = .swSurface) -> some View {
        modifier(SWSurfacePanel(cornerRadius: cornerRadius, fill: fill))
    }

    /// Floating glass panel (`.ultraThinMaterial` over a faint white fill,
    /// hairline stroke). For panels that float over the waveform.
    func swGlassPanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(SWGlassPanel(cornerRadius: cornerRadius))
    }

    /// Quiet hover cue: a 1px accent border that appears only on hover.
    func swAccentHoverBorder(cornerRadius: CGFloat = 8) -> some View {
        modifier(SWAccentHoverBorder(cornerRadius: cornerRadius))
    }

    /// Soft accent glow for the actively-analyzed / looped segment.
    func swAccentGlow() -> some View {
        shadow(color: Color.swAccent.opacity(0.5), radius: 8)
    }
}
