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
    /// Deep Phosphor fill for prominent commands, with a white label (5.5:1). Brand rule
    /// (2026-10-28): no text on a P31 Phosphor fill. Kept as RGB so the contrast test can measure
    /// the pair.
    static let prominentControlTint = SWRGBColor(hex: 0x0E7A24)
    static let prominentControlLabel = SWRGBColor.white
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
    /// Filled command controls and any green fill behind text or icons: Deep Phosphor
    /// (`actionFill`), never Phosphor (brand rule, 2026-10-28).
    static let swProminentControl = Color.Endogen.actionFill
    /// Label on `swProminentControl`: white (5.5:1).
    static let swProminentControlLabel = Color.Endogen.onActionFill
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
    /// Secondary / muted text: Mist (6.3:1 on Night), or Text `C3CCD6` (11.7:1) when Increase
    /// Contrast is on.
    static let swTextSecondary = Color.swHighContrastAware(
        normal: 0x8B96A3, increased: 0xC3CCD6)
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

// MARK: - Localization

extension Bundle {
    /// Where `Localizable.xcstrings` compiles to: the SwiftPM resource bundle under `swift build`
    /// and `swift test` (so plural variants resolve in tests), the app bundle under Xcode/Tuist.
    static var swStrings: Bundle {
        #if SWIFT_PACKAGE
            .module
        #else
            .main
        #endif
    }
}

// MARK: - Increase Contrast

#if os(macOS)
    import AppKit

    extension NSAppearance {
        /// True under System Settings › Accessibility › Display › Increase contrast. The app
        /// forces dark, so the appearance is `darkAqua` or its high-contrast twin.
        var swIsHighContrast: Bool {
            // The window's forced dark appearance may not carry the high-contrast variant, so
            // the system flag decides too.
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                || bestMatch(from: [
                    .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
                    .darkAqua, .aqua,
                ]) == .accessibilityHighContrastDarkAqua
                || bestMatch(from: [.accessibilityHighContrastAqua, .aqua])
                    == .accessibilityHighContrastAqua
        }
    }
#endif

extension Color {
    /// A color that resolves to `increased` when Increase Contrast is on. Resolved by AppKit per
    /// drawing appearance, so every existing `.foregroundStyle(Color.sw…)` site follows the
    /// setting without reading the environment.
    static func swHighContrastAware(normal: UInt32, increased: UInt32) -> Color {
        #if os(macOS)
            Color(
                nsColor: NSColor(name: nil) { appearance in
                    NSColor(Color(hex: appearance.swIsHighContrast ? increased : normal))
                })
        #else
            Color(hex: normal)
        #endif
    }

    /// `opacity(alpha)`, except under Increase Contrast, where the dimming drops and the color
    /// draws solid. Use for de-emphasis that would otherwise cost text or icon contrast.
    func swDimmed(_ alpha: Double) -> Color {
        #if os(macOS)
            let base = NSColor(self)
            return Color(
                nsColor: NSColor(name: nil) { appearance in
                    var resolved = base
                    appearance.performAsCurrentDrawingAppearance {
                        resolved = base.usingColorSpace(.sRGB) ?? base
                    }
                    return appearance.swIsHighContrast
                        ? resolved : resolved.withAlphaComponent(resolved.alphaComponent * alpha)
                })
        #else
            return opacity(alpha)
        #endif
    }
}

// MARK: - Typography
//
// The brand faces, bundled under `Resources/Fonts` (SIL OFL) and registered at launch by
// `EndogenFonts.registerBundled()`. Sizes stay the app's own: the brand's type scale (body 17)
// is sized for the web and too large for this dense tool UI.

/// The app-wide text size (Settings › Text, View › Bigger / Smaller Text, ⌘+ / ⌘−).
///
/// macOS has no system Dynamic Type: SwiftUI ignores `dynamicTypeSize` and text styles render
/// at fixed sizes (checked 2026-10-28: `.body` measures the same at `.large` and
/// `.accessibility5`). So the app scales its own text. Every `Font.swDisplay` / `Font.swMono`
/// call multiplies its authored size by `factor`; because the read goes through an
/// `ObservationRegistrar`, any view body that builds one of those fonts re-renders when the
/// factor changes, with no `.id` reset of view state.
///
/// The ChordPro chart is the exception: its glyphs and its horizontal time axis must scale
/// together, so it takes the factor through `ChordProChartScale` (see `Font.swChartMono`).
final class SWTextScale: Observable, @unchecked Sendable {
    static let shared = SWTextScale()

    /// The `UserDefaults` key the factor persists under.
    static let defaultsKey = "textScale"
    /// The steps ⌘+ / ⌘− walk through. 1 is the authored size; 2 roughly matches the jump from
    /// macOS's default to its largest "Text size" setting in system apps.
    static let steps: [CGFloat] = [0.85, 1, 1.15, 1.3, 1.5, 1.75, 2]

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var storedFactor: CGFloat

    init(defaults: UserDefaults = .standard) {
        let saved = defaults.double(forKey: Self.defaultsKey)
        storedFactor = Self.clamped(saved > 0 ? CGFloat(saved) : 1)
    }

    var factor: CGFloat {
        get {
            registrar.access(self, keyPath: \.factor)
            return lock.withLock { storedFactor }
        }
        set {
            let value = Self.clamped(newValue)
            registrar.withMutation(of: self, keyPath: \.factor) {
                lock.withLock { storedFactor = value }
            }
            UserDefaults.standard.set(Double(value), forKey: Self.defaultsKey)
        }
    }

    var canIncrease: Bool { factor < (Self.steps.last ?? 1) - 0.001 }
    var canDecrease: Bool { factor > (Self.steps.first ?? 1) + 0.001 }

    func increase() {
        if let next = Self.steps.first(where: { $0 > factor + 0.001 }) { factor = next }
    }

    func decrease() {
        if let previous = Self.steps.last(where: { $0 < factor - 0.001 }) { factor = previous }
    }

    func reset() { factor = 1 }

    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(max(value, steps.first ?? 1), steps.last ?? 1)
    }
}

/// A length that sits beside text (a fixed label column, a status row's height) at the app text
/// size, so the text it holds does not clip when the user makes text bigger.
func swScaled(_ length: CGFloat) -> CGFloat {
    length * SWTextScale.shared.factor
}

extension Font {
    /// Display / label font: Space Grotesk, at `size` × the app text size (`SWTextScale`).
    static func swDisplay(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.Endogen.sans(size * SWTextScale.shared.factor, weight)
    }

    /// Monospaced font for numeric / technical data: JetBrains Mono, at `size` × the app text
    /// size (`SWTextScale`).
    static func swMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.Endogen.mono(size * SWTextScale.shared.factor, weight)
    }

    /// JetBrains Mono at exactly `size`, for the ChordPro chart only. The chart already folds the
    /// app text size into `ChordProChartScale` (so the glyphs, the measured character advance and
    /// the time axis grow together); multiplying again here would double-scale the glyphs and push
    /// words off their beat columns.
    static func swChartMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.Endogen.mono(size, weight)
    }

    /// Space Grotesk at exactly `size`, for chart labels sized from `ChordProChartScale`.
    static func swChartDisplay(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.Endogen.sans(size, weight)
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

// MARK: - Reduce Motion defaults

enum MotionDefaults {
    /// Default for the chart's bouncing balls (lyric, chord, chord-pop) when the user has never
    /// toggled them: on, unless Reduce Motion is on. A saved choice always wins, because
    /// `@AppStorage` only falls back to this when its key is absent.
    static var ballsDefault: Bool {
        #if os(macOS)
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
            !UIAccessibility.isReduceMotionEnabled
        #endif
    }
}

// MARK: - Hit targets

/// macOS minimum hit target (Apple UI Standards §4: 28 × 28 pt).
enum SWHitTarget {
    static let minimum: CGFloat = 28
}

/// A hit-test shape at least `minimumWidth` wide, centred on the view, for slim controls (the
/// mixer faders) whose drawn width must stay narrow.
struct SWWidenedHitShape: Shape {
    var minimumWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let extra = max(minimumWidth - rect.width, 0) / 2
        return Path(rect.insetBy(dx: -extra, dy: 0))
    }
}

/// Button style for small icon-only buttons (chevrons, trash, accept/edit): the label keeps its
/// look, and its clickable frame grows to at least 28 × 28 pt.
struct SWIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SWIconButtonBody(configuration: configuration)
    }

    private struct SWIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .frame(minWidth: SWHitTarget.minimum, minHeight: SWHitTarget.minimum)
                .contentShape(Rectangle())
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
        }
    }
}

extension ButtonStyle where Self == SWIconButtonStyle {
    /// Icon-only button with a 28 × 28 pt minimum hit target.
    static var swIcon: SWIconButtonStyle { SWIconButtonStyle() }
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
    /// Filled primary command: Deep Phosphor fill, white label (5.5:1).
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
