import Foundation

/// Turns the chord network's per-frame head probabilities into one chord per frame — a port of the
/// music-x-lab `XHMMDecoder.decode` (MIT) without beat constraints, the configuration its
/// `chord_recognition.py` ships. Each frame scores every chord in `vocabulary` by summing the log
/// probabilities of its triad, bass and extension classes; a Viterbi pass then pays
/// `changePenalty` for every change of chord. Pure; no I/O.
enum ChordNetDecoder {
    /// The network's six softmax heads, frame-major: `values[frame * classes + class]`.
    struct Heads: Sendable {
        var frames: Int
        var triad: [Float]
        var bass: [Float]
        var seventh: [Float]
        var ninth: [Float]
        var eleventh: [Float]
        var thirteenth: [Float]

        static let classes = [73, 13, 4, 4, 3, 3]
    }

    /// The vocabulary index chosen for each frame.
    static func decode(_ heads: Heads) -> [Int] {
        let frames = heads.frames
        guard frames > 0 else { return [] }
        let chordCount = vocabulary.count
        let tables = [
            heads.triad, heads.bass, heads.seventh, heads.ninth, heads.eleventh, heads.thirteenth,
        ]
        func logProbability(_ head: Int, _ frame: Int, _ index: Int) -> Float {
            log(max(tables[head][frame * Heads.classes[head] + index], 1e-30))
        }
        // The observation score of chord `chord` at `frame`. The bass index is stored -1...11 and
        // the bass head's class 0 is "no bass", hence the + 1; extensions are skipped where -1.
        func observation(_ frame: Int, _ chord: Int) -> Float {
            let indices = vocabulary[chord].heads
            var score =
                logProbability(0, frame, indices[0]) + logProbability(1, frame, indices[1] + 1)
            for head in 2..<6 where indices[head] >= 0 {
                score += logProbability(head, frame, indices[head])
            }
            return score
        }

        var previous = [Float](repeating: -.infinity, count: chordCount)
        previous[0] = observation(0, 0)  // a song starts on "no chord", as the reference does
        var back = [Int32](repeating: 0, count: frames * chordCount)
        var current = [Float](repeating: 0, count: chordCount)
        var bestPrevious = 0
        for frame in 1..<frames {
            let switched = previous[bestPrevious] - changePenalty
            var best = 0
            for chord in 0..<chordCount {
                let stay = previous[chord]
                if stay > switched {
                    current[chord] = stay
                    back[frame * chordCount + chord] = Int32(chord)
                } else {
                    current[chord] = switched
                    back[frame * chordCount + chord] = Int32(bestPrevious)
                }
                current[chord] += observation(frame, chord)
                if current[chord] > current[best] { best = chord }
            }
            swap(&previous, &current)
            bestPrevious = best
        }
        var path = [Int](repeating: 0, count: frames)
        path[frames - 1] = previous.indices.max { previous[$0] < previous[$1] } ?? 0
        for frame in stride(from: frames - 1, to: 0, by: -1) {
            path[frame - 1] = Int(back[frame * chordCount + path[frame]])
        }
        return path
    }

    /// The app's spelling of a decoder label, or nil for "no chord". The bass note of an inversion
    /// is dropped (Eric, 2026-09-27: no slash chords on the chord line): "G:maj/3" reads "G".
    static func appLabel(_ harte: String) -> String? {
        guard harte != "N", harte != "X" else { return nil }
        let parts = harte.split(separator: ":", maxSplits: 1).map(String.init)
        let root = parts[0]
        let quality =
            parts.count > 1 ? (parts[1].split(separator: "/").first.map(String.init) ?? "") : "maj"
        let suffix: String
        switch quality {
        case "maj", "": suffix = ""
        case "min": suffix = "m"
        case "7": suffix = "7"
        case "maj7": suffix = "maj7"
        case "min7": suffix = "m7"
        case "dim": suffix = "dim"
        case "dim7": suffix = "dim7"
        case "hdim7": suffix = "m7b5"
        case "aug": suffix = "aug"
        case "sus2": suffix = "sus2"
        case "sus4": suffix = "sus4"
        case "sus4(b7)": suffix = "7sus4"
        case "9": suffix = "9"
        case "maj9": suffix = "maj9"
        case "min9": suffix = "m9"
        case "11": suffix = "11"
        case "13": suffix = "13"
        default: suffix = ""
        }
        return root + suffix
    }
}
