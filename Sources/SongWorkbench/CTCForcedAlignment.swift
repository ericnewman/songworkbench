import Foundation

/// Forced alignment of a KNOWN token sequence to a CTC posteriorgram.
///
/// This is the measurement that replaces every heuristic that used to move word times. Given the
/// frames an acoustic model emitted and the tokens we already know were sung, Viterbi finds the
/// maximum-likelihood assignment of frames to tokens. The result sits on the audio BY
/// CONSTRUCTION — there is no step afterwards that nudges, spreads or redistributes anything, and
/// there must never be one. A word whose frames the path never visits is a word we could not
/// measure; it is reported as unmeasured, not placed by arithmetic.
///
/// The lattice is the standard blank-expanded one: `[b, t0, b, t1, b, … , tN-1, b]`, `2N+1` states.
/// From state `s` the path may stay at `s`, advance to `s+1`, or skip to `s+2` — the skip only when
/// `s+2` is a real token that differs from `s`, which is what stops two identical adjacent tokens
/// from collapsing into one.
enum CTCForcedAlignment {

    /// One token's measured extent, in frame indices into the posteriorgram.
    struct TokenSpan: Equatable, Sendable {
        let token: Int
        /// Index of this token in the input sequence.
        let index: Int
        let startFrame: Int
        let endFrame: Int
    }

    enum Failure: Error, Equatable {
        /// More tokens than frames can encode: a CTC path needs a frame per token plus one per
        /// repeated pair, so below that no alignment exists at all.
        case audioTooShort(frames: Int, minimumRequired: Int)
        case emptyInput
    }

    /// Aligns `tokens` to `logProbs`.
    ///
    /// - Parameters:
    ///   - logProbs: `[frame][class]` log-probabilities. Rows need not be normalised; Viterbi only
    ///     compares sums along competing paths.
    ///   - tokens: the known token sequence, as class indices.
    ///   - blank: the CTC blank class index.
    /// - Returns: one span per token, in input order.
    static func align(
        logProbs: [[Float]],
        tokens: [Int],
        blank: Int
    ) throws -> [TokenSpan] {
        let frameCount = logProbs.count
        guard frameCount > 0, !tokens.isEmpty else { throw Failure.emptyInput }

        // A repeat needs a blank wedged between the two, so it costs an extra frame.
        let repeats = zip(tokens, tokens.dropFirst()).reduce(0) { $0 + ($1.0 == $1.1 ? 1 : 0) }
        let minimumFrames = tokens.count + repeats
        guard frameCount >= minimumFrames else {
            throw Failure.audioTooShort(frames: frameCount, minimumRequired: minimumFrames)
        }

        // Blank-expanded state sequence.
        var extended: [Int] = [blank]
        extended.reserveCapacity(2 * tokens.count + 1)
        for token in tokens {
            extended.append(token)
            extended.append(blank)
        }
        let stateCount = extended.count

        let negativeInfinity = -Float.greatestFiniteMagnitude
        var previous = [Float](repeating: negativeInfinity, count: stateCount)
        var current = [Float](repeating: negativeInfinity, count: stateCount)
        // Backpointers: which state we came from, one byte of choice per state per frame.
        var backpointers = [Int32](repeating: -1, count: frameCount * stateCount)

        // A path may open on the leading blank or on the first token.
        previous[0] = logProbs[0][blank]
        if stateCount > 1 { previous[1] = logProbs[0][extended[1]] }

        for frame in 1..<frameCount {
            let row = logProbs[frame]
            let base = frame * stateCount
            for state in 0..<stateCount {
                // Staying in `state` is always available.
                var best = previous[state]
                var from = state

                if state >= 1, previous[state - 1] > best {
                    best = previous[state - 1]
                    from = state - 1
                }
                // The skip is only legal into a real token that differs from the one two back;
                // without that guard "hello" would lose one of its l's.
                if state >= 2, extended[state] != blank, extended[state] != extended[state - 2],
                    previous[state - 2] > best
                {
                    best = previous[state - 2]
                    from = state - 2
                }

                if best == negativeInfinity {
                    current[state] = negativeInfinity
                    backpointers[base + state] = -1
                } else {
                    current[state] = best + row[extended[state]]
                    backpointers[base + state] = Int32(from)
                }
            }
            swap(&previous, &current)
        }

        // The path ends on the final blank or the final token.
        var state = stateCount - 1
        if stateCount >= 2, previous[stateCount - 2] > previous[stateCount - 1] {
            state = stateCount - 2
        }

        // Walk back, recording the frames each state occupied.
        var statePerFrame = [Int](repeating: 0, count: frameCount)
        for frame in stride(from: frameCount - 1, through: 0, by: -1) {
            statePerFrame[frame] = state
            if frame > 0 {
                let previousState = backpointers[frame * stateCount + state]
                guard previousState >= 0 else { break }
                state = Int(previousState)
            }
        }

        // Odd states are the real tokens; state 2i+1 is tokens[i].
        var firstFrame = [Int](repeating: -1, count: tokens.count)
        var lastFrame = [Int](repeating: -1, count: tokens.count)
        for (frame, occupied) in statePerFrame.enumerated() where occupied % 2 == 1 {
            let tokenIndex = (occupied - 1) / 2
            if firstFrame[tokenIndex] < 0 { firstFrame[tokenIndex] = frame }
            lastFrame[tokenIndex] = frame
        }

        return tokens.indices.map { index in
            TokenSpan(
                token: tokens[index],
                index: index,
                startFrame: firstFrame[index],
                endFrame: lastFrame[index]
            )
        }
    }
}
