import Foundation

struct StemMixState: Codable, Equatable, Sendable {
    /// Upper bound for a stem's gain. Above unity so quiet stems (e.g. a low bass stem) can
    /// be boosted; 2.0 ≈ +6 dB of headroom.
    static let maximumGain: Float = 2

    var gain: Float
    var isMuted: Bool
    var isSoloed: Bool

    init(gain: Float = 1, isMuted: Bool = false, isSoloed: Bool = false) {
        self.gain = min(max(gain, 0), Self.maximumGain)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

struct StemMixerModel: Codable, Equatable, Sendable {
    private var states: [StemKind: StemMixState]

    init() {
        states = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0, StemMixState()) })
    }

    subscript(kind: StemKind) -> StemMixState {
        states[kind] ?? StemMixState()
    }

    mutating func setGain(_ gain: Float, for kind: StemKind) {
        update(kind) { $0.gain = min(max(gain, 0), StemMixState.maximumGain) }
    }

    mutating func setMuted(_ isMuted: Bool, for kind: StemKind) {
        update(kind) { $0.isMuted = isMuted }
    }

    mutating func setSoloed(_ isSoloed: Bool, for kind: StemKind) {
        update(kind) { $0.isSoloed = isSoloed }
    }

    func effectiveGain(for kind: StemKind) -> Float {
        let state = self[kind]
        guard !state.isMuted else { return 0 }
        let hasSolo = StemKind.allCases.contains { self[$0].isSoloed }
        guard !hasSolo || state.isSoloed else { return 0 }
        return state.gain
    }

    private mutating func update(_ kind: StemKind, _ change: (inout StemMixState) -> Void) {
        var state = self[kind]
        change(&state)
        states[kind] = state
    }
}
