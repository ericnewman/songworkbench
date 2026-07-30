import Foundation

struct StemMixState: Codable, Equatable, Sendable {
    /// Upper bound for a stem's gain. Above unity so quiet stems (e.g. a low bass stem) can
    /// be boosted; 2.0 ≈ +6 dB of headroom.
    static let maximumGain: Float = 2

    var gain: Float
    var isMuted: Bool
    var isSoloed: Bool
    /// Stereo position, −1 (hard left) … 0 (center) … +1 (hard right) — a traditional
    /// mixer pan pot per stem.
    var pan: Float

    init(gain: Float = 1, isMuted: Bool = false, isSoloed: Bool = false, pan: Float = 0) {
        self.gain = min(max(gain, 0), Self.maximumGain)
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.pan = min(max(pan, -1), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case gain
        case isMuted
        case isSoloed
        case pan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `pan` arrived after documents were already in the field; missing = center.
        self.init(
            gain: try container.decode(Float.self, forKey: .gain),
            isMuted: try container.decode(Bool.self, forKey: .isMuted),
            isSoloed: try container.decode(Bool.self, forKey: .isSoloed),
            pan: try container.decodeIfPresent(Float.self, forKey: .pan) ?? 0
        )
    }
}

struct StemMixerModel: Codable, Equatable, Sendable {
    /// Upper bound for the master fader. Unlike a per-stem `gain`, the master sits downstream
    /// of every stem's own headroom, driving `AVAudioMixerNode.outputVolume` directly — which
    /// is only valid in 0...1 — so there's no +6 dB boost room here, just attenuation.
    static let maximumMasterGain: Float = 1

    private var states: [StemID: StemMixState]
    /// Overall output level, applied downstream of every stem (and the click). Always
    /// available regardless of which stems are loaded — it isn't gated by per-stem state the
    /// way `effectiveGain(for:)` is.
    var masterGain: Float

    init() {
        states = Dictionary(uniqueKeysWithValues: StemKind.allCases.map { ($0.id, StemMixState()) })
        masterGain = Self.maximumMasterGain
    }

    private enum CodingKeys: String, CodingKey {
        case states
        case masterGain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idStates = try? container.decode([StemID: StemMixState].self, forKey: .states) {
            states = idStates
        } else {
            let legacyStates = try container.decode([StemKind: StemMixState].self, forKey: .states)
            states = Dictionary(uniqueKeysWithValues: legacyStates.map { ($0.key.id, $0.value) })
        }
        // `masterGain` arrived after documents were already in the field; missing = unity.
        masterGain =
            try container.decodeIfPresent(Float.self, forKey: .masterGain)
            ?? Self.maximumMasterGain
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(states, forKey: .states)
        try container.encode(masterGain, forKey: .masterGain)
    }

    subscript(id: StemID) -> StemMixState {
        states[id] ?? StemMixState()
    }

    subscript(kind: StemKind) -> StemMixState {
        self[kind.id]
    }

    mutating func setGain(_ gain: Float, for id: StemID) {
        update(id) { $0.gain = min(max(gain, 0), StemMixState.maximumGain) }
    }

    mutating func setGain(_ gain: Float, for kind: StemKind) {
        setGain(gain, for: kind.id)
    }

    mutating func setMuted(_ isMuted: Bool, for id: StemID) {
        update(id) { $0.isMuted = isMuted }
    }

    mutating func setMuted(_ isMuted: Bool, for kind: StemKind) {
        setMuted(isMuted, for: kind.id)
    }

    mutating func setSoloed(_ isSoloed: Bool, for id: StemID) {
        update(id) { $0.isSoloed = isSoloed }
    }

    mutating func setSoloed(_ isSoloed: Bool, for kind: StemKind) {
        setSoloed(isSoloed, for: kind.id)
    }

    mutating func setPan(_ pan: Float, for id: StemID) {
        update(id) { $0.pan = min(max(pan, -1), 1) }
    }

    mutating func setPan(_ pan: Float, for kind: StemKind) {
        setPan(pan, for: kind.id)
    }

    mutating func setMasterGain(_ gain: Float) {
        masterGain = min(max(gain, 0), Self.maximumMasterGain)
    }

    func effectiveGain(for id: StemID, activeIDs: [StemID]? = nil) -> Float {
        let state = self[id]
        guard !state.isMuted else { return 0 }
        let soloScope = activeIDs ?? Array(states.keys)
        let hasSolo = soloScope.contains { self[$0].isSoloed }
        guard !hasSolo || state.isSoloed else { return 0 }
        return state.gain
    }

    func effectiveGain(for kind: StemKind) -> Float {
        effectiveGain(for: kind.id, activeIDs: StemKind.allCases.map(\.id))
    }

    private mutating func update(_ id: StemID, _ change: (inout StemMixState) -> Void) {
        var state = self[id]
        change(&state)
        states[id] = state
    }
}

struct StemMixerChannel: Identifiable, Equatable, Sendable {
    let id: StemID
    let displayName: String
    let order: Int
}

enum StemMixerChannelProjector {
    static func channels(for manifest: StemSetManifest) -> [StemMixerChannel] {
        let descriptors = manifest.descriptorsByID
        return StemMixGraph(manifest: manifest).activeNodes.compactMap { node in
            guard let descriptor = descriptors[node.id] else { return nil }
            return StemMixerChannel(
                id: node.id,
                displayName: descriptor.displayName,
                order: descriptor.order
            )
        }
    }
}

/// One waveform-card lane for an active frontier stem (base or refined child).
struct StemWaveformLaneModel: Identifiable, Equatable, Sendable {
    let id: StemID
    let displayName: String
    let envelope: WaveformEnvelope
}

enum StemWaveformLaneProjector {
    struct Target: Equatable, Sendable {
        let id: StemID
        let displayName: String
        let audioURL: URL
    }

    /// Same active parent/child frontier as the mixer: children replace their parent.
    static func targets(for manifest: StemSetManifest) -> [Target] {
        let descriptors = manifest.descriptorsByID
        return StemMixGraph(manifest: manifest).activeNodes.compactMap { node in
            guard let descriptor = descriptors[node.id] else { return nil }
            return Target(
                id: node.id,
                displayName: descriptor.displayName,
                audioURL: node.audioURL
            )
        }
    }
}
