import SwiftUI

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
    /// Primary accent: active selection / focus.
    static let swAccent = Color(hex: 0x339AF0)
    /// Secondary accent: errors / alerts ONLY.
    static let swCoral = Color(hex: 0xFF6B6B)
    /// Data highlight: waveform peaks / data values.
    static let swMint = Color(hex: 0x51CF66)
    /// Active-playback highlight: the currently sung/played lyric words.
    static let swAmber = Color(hex: 0xFFC107)
    /// Primary text.
    static let swTextPrimary = Color(hex: 0xE9ECEF)
    /// Secondary / muted text.
    static let swTextSecondary = Color(hex: 0xADB5BD)
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

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.swSurface)
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
    /// Surface-grey panel: fill + subtle 1px white stroke. For cards,
    /// editor containers, sidebars, inspector panels.
    func swSurfacePanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(SWSurfacePanel(cornerRadius: cornerRadius))
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
