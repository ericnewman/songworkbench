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

/// Codes a dictionary with a String-backed non-String key in the same alternating
/// `[key, value, …]` array `JSONEncoder` already writes for such keys, but sorted by key. The
/// unsorted form follows the per-process hash seed (`.sortedKeys` never reaches inside those
/// arrays), so every launch re-encoded every manifest to new bytes and `SplitProjectStore`'s
/// byte-diff rewrote them all. The on-disk format is unchanged, so existing manifests decode as
/// before.
@propertyWrapper
struct SortedKeyPairs<
    Key: Codable & Hashable & Sendable & RawRepresentable,
    Value: Codable & Equatable & Sendable
>: Codable, Equatable, Sendable where Key.RawValue == String {
    var wrappedValue: [Key: Value]

    init(wrappedValue: [Key: Value]) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        wrappedValue = try [Key: Value](from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var pairs = encoder.unkeyedContainer()
        for (key, value) in wrappedValue.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            try pairs.encode(key)
            try pairs.encode(value)
        }
    }
}

struct StemMixerModel: Codable, Equatable, Sendable {
    /// Upper bound for the master fader. Unlike a per-stem `gain`, the master sits downstream
    /// of every stem's own headroom, driving `AVAudioMixerNode.outputVolume` directly — which
    /// is only valid in 0...1 — so there's no +6 dB boost room here, just attenuation.
    static let maximumMasterGain: Float = 1

    @SortedKeyPairs private var states: [StemID: StemMixState]
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
        try container.encode(_states, forKey: .states)
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
        effectiveGain(for: id, activeIDs: activeIDs, parentByID: [:])
    }

    /// Gain for one audible stem, with refined stems treated as members of their parent's group:
    /// the parent is a BUS, so its fader scales every child and its mute/solo applies to all of
    /// them. `parentByID` comes from the stem manifest; pass `[:]` and this behaves exactly as the
    /// flat mixer did, which is what every non-hierarchical caller still gets.
    ///
    /// Only the children are actually playing (`StemMixGraph.activeNodes` drops any parent that
    /// has children), so a group fader has to reach the audio THROUGH its children — there is no
    /// separate bus node to attenuate.
    func effectiveGain(
        for id: StemID,
        activeIDs: [StemID]?,
        parentByID: [StemID: StemID]
    ) -> Float {
        let chain = Self.ancestry(of: id, parentByID: parentByID)
        // Muting a group mutes everything under it.
        guard !chain.contains(where: { self[$0].isMuted }) else { return 0 }
        let scope = activeIDs ?? Array(states.keys)
        // Soloing a group solos its children, so a solo anywhere in a playing stem's ancestry
        // counts — otherwise hitting S on "Vocals" would silence the very stems it names.
        let soloScope = Set(scope.flatMap { Self.ancestry(of: $0, parentByID: parentByID) })
        let hasSolo = soloScope.contains { self[$0].isSoloed }
        if hasSolo, !chain.contains(where: { self[$0].isSoloed }) { return 0 }
        return chain.reduce(Float(1)) { $0 * self[$1].gain }
    }

    /// `id` first, then each ancestor. Defensively bounded: a manifest with a parent cycle would
    /// otherwise hang the audio thread.
    private static func ancestry(of id: StemID, parentByID: [StemID: StemID]) -> [StemID] {
        var chain: [StemID] = []
        var seen: Set<StemID> = []
        var cursor: StemID? = id
        while let current = cursor, seen.insert(current).inserted {
            chain.append(current)
            cursor = parentByID[current]
        }
        return chain
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
    /// Refined stems that make up this one. Empty for an ordinary stem; when non-empty this
    /// channel is a GROUP: it is not itself playing, and its fader scales these children.
    let children: [StemMixerChannel]

    init(id: StemID, displayName: String, order: Int, children: [StemMixerChannel] = []) {
        self.id = id
        self.displayName = displayName
        self.order = order
        self.children = children
    }

    var isGroup: Bool { !children.isEmpty }
}

enum StemMixerChannelProjector {
    /// The console's strips, as a one-level tree: an ordinary stem is a leaf, and a stem that was
    /// refined into parts becomes a GROUP holding them. The refined parts used to simply replace
    /// their parent, which left no way to see that "Voice 1"/"Voice 2" were the vocals, and no
    /// single fader for them.
    static func channels(for manifest: StemSetManifest) -> [StemMixerChannel] {
        let descriptors = manifest.descriptorsByID
        let graph = StemMixGraph(manifest: manifest)
        let activeNodes = graph.activeNodes
        let numberedVocalNames = StemVoiceDisplayNames.numberedVocalNames(
            for: activeNodes,
            descriptorsByID: descriptors
        )
        func leaf(_ node: StemMixGraph.Node) -> StemMixerChannel? {
            guard let descriptor = descriptors[node.id] else { return nil }
            return StemMixerChannel(
                id: node.id,
                displayName: numberedVocalNames[node.id] ?? descriptor.displayName,
                order: descriptor.order
            )
        }
        var grouped: [StemID: [StemMixerChannel]] = [:]
        var roots: [StemMixerChannel] = []
        for node in activeNodes {
            guard let channel = leaf(node) else { continue }
            if let parentID = node.parentID, descriptors[parentID] != nil {
                grouped[parentID, default: []].append(channel)
            } else {
                roots.append(channel)
            }
        }
        for (parentID, children) in grouped {
            guard let descriptor = descriptors[parentID] else { continue }
            roots.append(
                StemMixerChannel(
                    id: parentID,
                    displayName: descriptor.displayName,
                    order: descriptor.order,
                    children: children.sorted { lhs, rhs in
                        lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
                    }
                ))
        }
        return roots.sorted { lhs, rhs in
            lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
        }
    }

    /// Every playing stem's parent, for `StemMixerModel.effectiveGain`.
    static func parentByID(for manifest: StemSetManifest) -> [StemID: StemID] {
        var map: [StemID: StemID] = [:]
        for descriptor in manifest.descriptors {
            if let parentID = descriptor.parentID { map[descriptor.id] = parentID }
        }
        return map
    }
}

/// One waveform-card lane for an active frontier stem (base or refined child).
struct StemWaveformLaneModel: Identifiable, Equatable, Sendable {
    let id: StemID
    let displayName: String
    let envelope: WaveformEnvelope
}

/// The instrument energy the Review chart draws under each row: every non-vocal stem summed into
/// one line, or one line per stem the user hasn't hidden (Eric, 2026-09-14 — a single guitar lane
/// read as "all guitar" on a piano song).
enum InstrumentEnergyLanes {
    /// The summed lane's ID. It is not a stem kind, so its lane color falls back to neutral gray.
    static let combinedID: StemID = "instruments"

    /// A lane whose loudest peak in a row is under this absolute level (about −34 dBFS) is
    /// separation bleed, not playing.
    static let quietFloor: Float = 0.02
    /// A lane under this share of the row's loudest lane is suppressed too.
    static let quietShareOfLoudest: Float = 0.15

    /// Indices of the lanes worth drawing in one row (Eric, 2026-09-14: an essentially quiet
    /// instrument's line is suppressed). `lanePeaks` holds each lane's peaks for the row.
    static func audibleLaneIndices(_ lanePeaks: [[Float]]) -> [Int] {
        let loudest = lanePeaks.compactMap { $0.max() }.max() ?? 0
        let threshold = max(quietFloor, quietShareOfLoudest * loudest)
        return lanePeaks.indices.filter { (lanePeaks[$0].max() ?? 0) >= threshold }
    }

    static func lanes(
        from stems: [StemWaveformLaneModel], perStem: Bool, hidden: Set<StemID>
    ) -> [StemWaveformLaneModel] {
        let vocalPrefix = StemKind.vocals.rawValue + "."
        let instruments = stems.filter {
            $0.id != StemKind.vocals.id && !$0.id.rawValue.hasPrefix(vocalPrefix)
                && $0.envelope.duration > 0 && !$0.envelope.peaks.isEmpty
        }
        if perStem { return instruments.filter { !hidden.contains($0.id) } }
        guard
            let grid = instruments.max(by: { $0.envelope.duration < $1.envelope.duration })?
                .envelope
        else { return [] }
        // Sum on the longest stem's sample grid, reading every stem at the same song time.
        let count = grid.peaks.count
        let summed = (0..<count).map { index -> Float in
            let time = (Double(index) + 0.5) / Double(count) * grid.duration
            return instruments.reduce(0) { total, stem in
                let envelope = stem.envelope
                guard time < envelope.duration else { return total }
                let sample = Int(time / envelope.duration * Double(envelope.peaks.count))
                return total + envelope.peaks[min(sample, envelope.peaks.count - 1)]
            }
        }
        return [
            StemWaveformLaneModel(
                id: combinedID, displayName: "Instruments",
                envelope: WaveformEnvelope(peaks: summed, duration: grid.duration))
        ]
    }
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
        let activeNodes = StemMixGraph(manifest: manifest).activeNodes
        let numberedVocalNames = StemVoiceDisplayNames.numberedVocalNames(
            for: activeNodes,
            descriptorsByID: descriptors
        )
        return activeNodes.compactMap { node in
            guard let descriptor = descriptors[node.id] else { return nil }
            return Target(
                id: node.id,
                displayName: numberedVocalNames[node.id] ?? descriptor.displayName,
                audioURL: node.audioURL
            )
        }
    }
}

enum StemVoiceDisplayNames {
    static func numberedVocalNames(
        for activeNodes: [StemMixGraph.Node],
        descriptorsByID: [StemID: StemDescriptor]
    ) -> [StemID: String] {
        let vocalChildren = activeNodes.filter { node in
            descriptorsByID[node.id]?.parentID == StemKind.vocals.id
        }
        guard !vocalChildren.isEmpty else { return [:] }

        return Dictionary(
            uniqueKeysWithValues: vocalChildren.enumerated().map { offset, node in
                (node.id, "Voice \(offset + 1)")
            }
        )
    }
}
