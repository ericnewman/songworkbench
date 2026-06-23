import SwiftUI

struct WaveformView: View {
    let envelope: WaveformEnvelope
    let currentTime: TimeInterval
    @Binding var loopRegion: LoopRegion?
    @State private var dragAnchor: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawWaveform(context: &context, size: size)
                drawLoop(context: &context, size: size)
                drawPlayhead(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(loopGesture(width: geometry.size.width))
            .accessibilityLabel("Song waveform")
            .accessibilityValue(accessibilityValue)
        }
        .frame(minHeight: 110)
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
        context.stroke(path, with: .color(.accentColor.opacity(0.75)), lineWidth: max(step, 1))
    }

    private func drawLoop(context: inout GraphicsContext, size: CGSize) {
        guard let loopRegion, envelope.duration > 0 else { return }
        let startX = size.width * loopRegion.start / envelope.duration
        let endX = size.width * loopRegion.end / envelope.duration
        let rect = CGRect(x: startX, y: 0, width: max(endX - startX, 1), height: size.height)
        context.fill(Path(rect), with: .color(.orange.opacity(0.18)))
        context.stroke(Path(rect), with: .color(.orange), lineWidth: 1.5)
    }

    private func drawPlayhead(context: inout GraphicsContext, size: CGSize) {
        guard envelope.duration > 0 else { return }
        let x = size.width * min(max(currentTime / envelope.duration, 0), 1)
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(path, with: .color(.primary), lineWidth: 2)
    }

    private func loopGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard width > 0, envelope.duration > 0 else { return }
                let time = envelope.duration * min(max(value.location.x / width, 0), 1)
                if dragAnchor == nil {
                    dragAnchor = envelope.duration * min(max(value.startLocation.x / width, 0), 1)
                }
                guard let dragAnchor else { return }
                loopRegion = LoopRegion(start: min(dragAnchor, time), end: max(dragAnchor, time))
            }
            .onEnded { _ in
                dragAnchor = nil
                loopRegion = loopRegion?.clamped(to: envelope.duration)
            }
    }

    private var accessibilityValue: String {
        guard let loopRegion else { return "No loop selected" }
        return "Loop from \(loopRegion.start.formatted()) to \(loopRegion.end.formatted()) seconds"
    }
}
