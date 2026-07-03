import SwiftUI

struct WaveformView: View {
    let envelope: WaveformEnvelope
    let currentTime: TimeInterval
    @Binding var loopRegion: LoopRegion?
    /// Detected singing intervals (from the vocals stem), shaded behind the waveform so the
    /// vocal-activity detection can be visually compared against the audio.
    var voicedIntervals: [ClosedRange<TimeInterval>] = []
    /// Called when the user drags the playhead handle to a new time (on release).
    /// When nil, the playhead is display-only and all drags select a loop.
    var onSeek: ((TimeInterval) -> Void)? = nil
    @State private var dragAnchor: TimeInterval?
    /// The playhead position while its handle is being dragged (drawn live; the actual
    /// seek fires once on release so playback isn't re-scheduled 60×/second).
    @State private var scrubTime: TimeInterval?
    private enum DragMode { case playhead, loop }
    @State private var dragMode: DragMode?

    /// Horizontal grab tolerance around the playhead line/handle, in points.
    private static let playheadGrabWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawWaveform(context: &context, size: size)
                drawVoicedIntervals(context: &context, size: size)
                drawLoop(context: &context, size: size)
                drawPlayhead(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: geometry.size.width))
            .accessibilityLabel("Song waveform")
            .accessibilityValue(accessibilityValue)
        }
        // No intrinsic min-height: the caller sizes each lane (the mix lane is 64pt). A min-height
        // taller than the lane made the Canvas render oversized and clip its top/bottom peaks.
    }

    private func drawVoicedIntervals(context: inout GraphicsContext, size: CGSize) {
        guard envelope.duration > 0, !voicedIntervals.isEmpty else { return }
        // A clear amber "vocal activity" lane along the bottom (on top of the waveform so it's
        // never occluded), plus a soft full-height tint to mark the sung regions.
        let laneHeight: CGFloat = 12
        for interval in voicedIntervals {
            let startX = size.width * min(max(interval.lowerBound / envelope.duration, 0), 1)
            let endX = size.width * min(max(interval.upperBound / envelope.duration, 0), 1)
            let width = max(endX - startX, 1.5)
            context.fill(
                Path(CGRect(x: startX, y: 0, width: width, height: size.height)),
                with: .color(.swAmber.opacity(0.14)))
            context.fill(
                Path(
                    CGRect(x: startX, y: size.height - laneHeight, width: width, height: laneHeight)
                ),
                with: .color(.swAmber.opacity(0.85)))
        }
    }

    private func drawWaveform(context: inout GraphicsContext, size: CGSize) {
        guard !envelope.peaks.isEmpty else { return }
        let centerY = size.height / 2
        let step = size.width / CGFloat(envelope.peaks.count)
        var path = Path()
        for (index, peak) in envelope.peaks.enumerated() {
            let x = CGFloat(index) * step
            let height = max(CGFloat(peak) * size.height * 0.9, 1)
            path.move(to: CGPoint(x: x, y: centerY - height / 2))
            path.addLine(to: CGPoint(x: x, y: centerY + height / 2))
        }
        context.stroke(path, with: .color(.swMint.opacity(0.85)), lineWidth: max(step, 1))
    }

    private func drawLoop(context: inout GraphicsContext, size: CGSize) {
        guard let loopRegion, envelope.duration > 0 else { return }
        let startX = size.width * loopRegion.start / envelope.duration
        let endX = size.width * loopRegion.end / envelope.duration
        let rect = CGRect(x: startX, y: 0, width: max(endX - startX, 1), height: size.height)
        // Actively-looped / analyzed segment: soft accent fill + accent border.
        context.fill(Path(rect), with: .color(.swAccent.opacity(0.18)))
        context.stroke(Path(rect), with: .color(.swAccent), lineWidth: 1.5)
    }

    private func drawPlayhead(context: inout GraphicsContext, size: CGSize) {
        guard envelope.duration > 0 else { return }
        let time = scrubTime ?? currentTime
        let x = size.width * min(max(time / envelope.duration, 0), 1)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        // Playhead in CORAL so it can't be confused with the accent-colored loop region.
        context.stroke(path, with: .color(.swCoral), lineWidth: 2)
        // Drag handle: a grab knob at the top of the line (slightly larger while dragging).
        if onSeek != nil {
            let radius: CGFloat = scrubTime == nil ? 5 : 6.5
            let knob = CGRect(
                x: x - radius, y: 0, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: knob), with: .color(.swCoral))
            context.stroke(
                Path(ellipseIn: knob), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
    }

    /// One gesture, two behaviors: a drag starting on/near the playhead line or its knob
    /// scrubs the playhead (seek fires on release); a drag anywhere else selects the loop
    /// region, exactly as before.
    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard width > 0, envelope.duration > 0 else { return }
                let time = envelope.duration * min(max(value.location.x / width, 0), 1)
                if dragMode == nil {
                    let playheadX =
                        width * CGFloat(min(max(currentTime / envelope.duration, 0), 1))
                    let startedOnPlayhead =
                        onSeek != nil
                        && abs(value.startLocation.x - playheadX) <= Self.playheadGrabWidth
                    dragMode = startedOnPlayhead ? .playhead : .loop
                }
                switch dragMode {
                case .playhead:
                    scrubTime = time
                case .loop:
                    if dragAnchor == nil {
                        dragAnchor =
                            envelope.duration * min(max(value.startLocation.x / width, 0), 1)
                    }
                    guard let dragAnchor else { return }
                    loopRegion = LoopRegion(
                        start: min(dragAnchor, time), end: max(dragAnchor, time))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                switch dragMode {
                case .playhead:
                    if let scrubTime { onSeek?(scrubTime) }
                    scrubTime = nil
                case .loop, nil:
                    loopRegion = loopRegion?.clamped(to: envelope.duration)
                }
                dragAnchor = nil
                dragMode = nil
            }
    }

    private var accessibilityValue: String {
        guard let loopRegion else { return "No loop selected" }
        return "Loop from \(loopRegion.start.formatted()) to \(loopRegion.end.formatted()) seconds"
    }
}

/// A single compact stem waveform lane. Draws the stem's peaks across its width on a time axis
/// shared with the full-mix waveform: x is mapped by time using `totalDuration` (the full-mix
/// duration) so every lane lines up vertically with the mix above it. In practice the stem and mix
/// durations match, so peaks fill the lane; if a stem is shorter it only fills its proportional
/// span, keeping the time scale consistent.
struct StemWaveformLane: View {
    let envelope: WaveformEnvelope
    let color: Color
    /// The full-mix duration, used as the shared x-axis scale for all lanes.
    let totalDuration: TimeInterval
    var height: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            drawLane(context: &context, size: size)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func drawLane(context: inout GraphicsContext, size: CGSize) {
        guard !envelope.peaks.isEmpty, totalDuration > 0 else { return }
        let centerY = size.height / 2
        // Fraction of the shared timeline this stem spans (1.0 when durations match).
        let spanFraction = min(max(envelope.duration / totalDuration, 0), 1)
        let laneWidth = size.width * CGFloat(spanFraction)
        let step = laneWidth / CGFloat(envelope.peaks.count)
        var path = Path()
        for (index, peak) in envelope.peaks.enumerated() {
            let x = CGFloat(index) * step
            let barHeight = max(CGFloat(peak) * size.height * 0.9, 1)
            path.move(to: CGPoint(x: x, y: centerY - barHeight / 2))
            path.addLine(to: CGPoint(x: x, y: centerY + barHeight / 2))
        }
        context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: max(step, 1))
    }
}
