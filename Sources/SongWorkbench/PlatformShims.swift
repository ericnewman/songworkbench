import AVFoundation
import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// PlatformShims: the single home for small macOS/iPadOS API bridges used by shared
// sources. Wholesale-mac flows (NSOpenPanel/NSSavePanel, menu-bar commands, JustChords
// hand-off) stay in their own files behind `#if os(macOS)`; only APIs with a direct,
// low-risk equivalent on both platforms live here. Keep additions tiny and behavior-
// preserving on macOS: the mac app must be bit-for-bit unaffected by the iPad port.

/// Screen metrics without touching `NSScreen`/`UIScreen` at call sites.
enum PlatformScreen {
    /// Height of the main screen's usable area. On iPadOS the app doesn't own the
    /// screen (Split View, Stage Manager), so the fallback is used; window-relative
    /// sizing should come from the layout pass there instead.
    static func visibleHeight(fallback: CGFloat = 900) -> CGFloat {
        #if os(macOS)
            return NSScreen.main?.visibleFrame.height ?? fallback
        #else
            return fallback
        #endif
    }
}

/// Platform font for text measurement (`NSFont` / `UIFont` share the relevant API:
/// `monospacedSystemFont(ofSize:weight:)` and `NSAttributedString` sizing).
#if os(macOS)
    typealias PlatformFont = NSFont
#elseif canImport(UIKit)
    typealias PlatformFont = UIFont
#endif

/// App-lifecycle notifications (NSApplication vs UIApplication).
enum PlatformLifecycle {
    static var willTerminateNotification: Notification.Name {
        #if os(macOS)
            return NSApplication.willTerminateNotification
        #else
            return UIApplication.willTerminateNotification
        #endif
    }
}

/// AVAudioSession setup. macOS has no session concept (no-op); iOS requires a
/// category to be set before any `AVAudioEngine` render/IO starts, or output is
/// silent / capture fails.
enum PlatformAudioSession {
    static func configureForPlayback() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        #endif
    }
}

/// Core Audio HAL device IDs exist only on macOS; iOS input selection goes through
/// `AVAudioSession` ports instead. The typealias keeps shared signatures compiling.
#if os(macOS)
    typealias PlatformAudioDeviceID = AudioDeviceID
#else
    typealias PlatformAudioDeviceID = UInt32
#endif

/// Screen-recording (system audio capture) preflight; that whole capture path is
/// macOS-only, so iOS reports "not granted / unsupported".
enum PlatformCapture {
    static func screenRecordingPreflight() -> Bool {
        #if os(macOS)
            return CGPreflightScreenCaptureAccess()
        #else
            return false
        #endif
    }
}

extension Color {
    /// `NSColor.textBackgroundColor` has no UIKit twin; `systemBackground` is the
    /// closest visual equivalent for text-document surfaces on iPadOS.
    static var swTextBackground: Color {
        #if os(macOS)
            return Color(nsColor: .textBackgroundColor)
        #else
            return Color(uiColor: .systemBackground)
        #endif
    }
}

extension URL {
    /// Security-scoped bookmark creation: macOS needs the explicit
    /// `.withSecurityScope` app-scope option (and the matching entitlement); on iOS
    /// bookmarks of document-picker URLs are implicitly security-scoped and the
    /// macOS option doesn't exist.
    func appScopedBookmarkData() throws -> Data {
        #if os(macOS)
            return try bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #else
            return try bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        #endif
    }

    /// Counterpart of `appScopedBookmarkData()` for resolution.
    init(resolvingAppScopedBookmark data: Data, bookmarkDataIsStale: inout Bool) throws {
        #if os(macOS)
            try self.init(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkDataIsStale
            )
        #else
            try self.init(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkDataIsStale
            )
        #endif
    }
}

/// `VSplitView` (draggable divider) on macOS; a plain `VStack` on iPadOS until a
/// proper adaptive layout replaces it. Children are forwarded as-is, so on macOS the
/// panes behave exactly like the previous direct `VSplitView` usage.
struct PlatformVSplit<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(macOS)
            VSplitView { content() }
        #else
            VStack(spacing: 0) { content() }
        #endif
    }
}

extension View {
    /// `.onExitCommand` (Escape) exists on macOS/tvOS only; no-op on iPadOS.
    @ViewBuilder
    func onExitCommandCompat(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
            onExitCommand(perform: action)
        #else
            self
        #endif
    }

    /// Hides the system navigation bar. macOS renders `.navigationTitle` in the window's own
    /// title bar and never draws this row, so hiding it there is a no-op; on iPadOS it's a full
    /// large-title banner sitting above our own compact collapsible header — pure wasted
    /// vertical space once we already show the song name and status ourselves (Eric: "still a
    /// lot of wasted space at the top of the iPad screen", 2026-07-06).
    @ViewBuilder
    func hideSystemNavigationBarCompat() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .navigationBar)
        #else
            self
        #endif
    }
}
