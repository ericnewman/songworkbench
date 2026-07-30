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
    /// Open Color blue 8. Dark enough for normal-sized white button labels to exceed 4.5:1.
    static let prominentControlTint = SWRGBColor(hex: 0x1971C2)
}

// MARK: - Color Palette
//
// A single, centralized source of truth for SongWorkbench's dark theme.
// Reference these tokens from views instead of scattering raw hex literals.
//
// Saturation == importance. Knobs / sliders / buttons / nav stay monochrome
// grey; vibrant color is reserved for DATA (waveform peaks), the active
// selection / focus (accent), and error states (coral).

extension Color {
    /// Builds an opaque sRGB color from a 24-bit hex value (0xRRGGBB).
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }

    /// App background / workspace canvas.
    static let swCanvas = Color(hex: 0x1A1B1E)
    /// Panels / menus / cards.
    static let swSurface = Color(hex: 0x25262B)
    /// A touch lighter than `swSurface` — for panels that should read as sitting forward of
    /// the ones around them (the Stem Mix console, so its controls have somewhere to cast a
    /// shadow onto).
    static let swSurfaceRaised = Color(hex: 0x2C2E34)
    /// Primary accent: active selection / focus.
    static let swAccent = Color(hex: 0x339AF0)
    /// Filled command controls. Kept darker than `swAccent` for readable white labels.
    static let swProminentControl = Color(
        .sRGB,
        red: SWColorPalette.prominentControlTint.red,
        green: SWColorPalette.prominentControlTint.green,
        blue: SWColorPalette.prominentControlTint.blue,
        opacity: 1
    )
    /// Secondary accent: errors / alerts ONLY.
    static let swCoral = Color(hex: 0xFF6B6B)
    /// Data highlight: waveform peaks / data values.
    static let swMint = Color(hex: 0x51CF66)
    /// Active-playback highlight: the currently sung/played lyric words.
    static let swAmber = Color(hex: 0xFFC107)
    /// Violet — used for a stem lane that needs to stay distinct from amber/mint/blue.
    static let swViolet = Color(hex: 0xCC5DE8)
    /// Primary text.
    static let swTextPrimary = Color(hex: 0xE9ECEF)
    /// Secondary / muted text.
    static let swTextSecondary = Color(hex: 0xADB5BD)
}

extension StemKind {
    /// The lane color for this stem in the waveform panel. Single source of truth so the ChordPro
    /// per-line audio strip matches the stem it's drawn from (vocals = amber, guitar = violet,
    /// piano = white, …) and the two can't drift apart.
    var laneColor: Color {
        switch self {
        case .vocals: .swAmber
        case .drums: .swCoral
        case .bass: .swAccent
        case .guitar: .swViolet
        case .piano: .swTextPrimary
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
// System fonts only (SF Pro / SF Mono equivalents). No bundled font files.

extension Font {
    /// Display / label font (SF Pro — the system default).
    static func swDisplay(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced font (SF Mono equivalent) for numeric / technical data:
    /// BPM, durations, frequencies, semitones, file metadata.
    static func swMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
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
    /// Filled primary command with a WCAG AA-compliant white-label background.
    func swProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
            .tint(Color.swProminentControl)
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
