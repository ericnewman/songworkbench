import Foundation

/// Assigns sung notes to voice rows by timbre rather than by pitch rank, so a single singer keeps
/// one row even when two vocal lines cross in pitch. Pure and app-type-free on purpose: the caller
/// adapts its own note model into `Note` and reads back a parallel array of row indices.
struct VocalTimbreClustering {
    struct Note {
        let start: TimeInterval
        let end: TimeInterval
        /// MIDI note number.
        let pitch: Int
        /// Unit-L2 harmonic envelope; nil when the extractor could not produce one.
        let timbre: [Float]?
        /// Which vocal stem this note came from. When lead and backing stems exist, this is a far
        /// stronger identity signal than the envelope — a whole separation model produced it — so
        /// notes from different stems are never merged into one voice.
        let source: String?

        init(
            start: TimeInterval,
            end: TimeInterval,
            pitch: Int,
            timbre: [Float]? = nil,
            source: String? = nil
        ) {
            self.start = start
            self.end = end
            self.pitch = pitch
            self.timbre = timbre
            self.source = source
        }
    }

    // ponytail: tuned constant. 0.35 cosine distance separates two singers on the synthetic and
    // real envelopes we have; it is a single global cut with no per-song adaptation. Upgrade path
    // if it proves too blunt: derive the threshold from the observed within-song distance
    // distribution (e.g. a gap statistic over sorted pairwise distances), or learn it offline.
    static let timbreDistanceThreshold: Float = 0.35

    /// Song-level voice identity: one pass over EVERY note in the song, so a singer keeps the same
    /// number everywhere. Never call this per visible window — clustering a handful of notes at a
    /// time re-derives the centroids and re-ranks them, which is how a singer ends up as Voice 1 on
    /// one lyric line and Voice 2 on the next.
    ///
    /// Notes are partitioned by `source` first (different stems are different voices by
    /// construction), and timbre only subdivides within a stem.
    static func voices(for notes: [Note], maximumVoices: Int) -> [Int] {
        guard !notes.isEmpty else { return [] }
        let cap = max(1, maximumVoices)
        let sources = orderedSources(notes)
        // Split the voice budget across stems so the total can never exceed the cap.
        let perSource = max(1, cap / sources.count)

        var groupOf = [Int](repeating: 0, count: notes.count)
        var groupMembers: [[Int]] = []
        for source in sources {
            let indices = notes.indices.filter { key(notes[$0].source) == source }
            let local = clusterRows(indices.map { notes[$0] }, rowCap: perSource)
            var byLocalCluster: [Int: [Int]] = [:]
            for (offset, index) in indices.enumerated() {
                byLocalCluster[local[offset] ?? 0, default: []].append(index)
            }
            for cluster in byLocalCluster.keys.sorted() {
                groupMembers.append(byLocalCluster[cluster] ?? [])
            }
        }
        // Rank every cluster from every stem together by median pitch, so Voice 1 is the lowest
        // part of the song as a whole.
        let ranking = groupMembers.indices.sorted {
            let a = medianPitch(groupMembers[$0], notes)
            let b = medianPitch(groupMembers[$1], notes)
            if a != b { return a < b }
            return $0 < $1
        }
        for (voice, group) in ranking.enumerated() {
            for index in groupMembers[group] { groupOf[index] = min(voice, cap - 1) }
        }
        return groupOf
    }

    private static func key(_ source: String?) -> String { source ?? "" }

    private static func orderedSources(_ notes: [Note]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for note in notes {
            let id = key(note.source)
            if seen.insert(id).inserted { ordered.append(id) }
        }
        return ordered.sorted()
    }

    /// Returns one row index per input note, parallel to `notes`.
    ///
    /// `preassigned` carries the song-level voice from `voices(for:maximumVoices:)` when it has
    /// already been computed (it is persisted on each observation at analysis time). Rows still go
    /// through collision resolution because two notes of the SAME voice can overlap in time.
    static func rows(
        for notes: [Note],
        maximumRows: Int,
        preassigned: [Int?]? = nil
    ) -> [Int] {
        guard !notes.isEmpty else { return [] }
        let rowCap = max(1, maximumRows)
        let fallback = pitchRankRows(notes, rowCap: rowCap)

        if let preassigned, preassigned.count == notes.count,
            preassigned.contains(where: { $0 != nil })
        {
            let desired = notes.indices.map { index in
                min(max(preassigned[index] ?? fallback[index], 0), rowCap - 1)
            }
            return resolveCollisions(notes, desired: desired, fallback: fallback, rowCap: rowCap)
        }

        let timbredCount = notes.reduce(into: 0) { $0 += ($1.timbre?.isEmpty == false ? 1 : 0) }
        guard timbredCount >= 2 else { return fallback }

        let clusterRow = clusterRows(notes, rowCap: rowCap)

        // Desired row: timbre cluster where we have one, pitch rank otherwise.
        var desired = [Int](repeating: 0, count: notes.count)
        for index in notes.indices {
            desired[index] = clusterRow[index] ?? fallback[index]
        }

        return resolveCollisions(notes, desired: desired, fallback: fallback, rowCap: rowCap)
    }

    // MARK: - Pitch rank

    /// A note's row is the number of simultaneously-sounding notes ranked below it.
    private static func pitchRankRows(_ notes: [Note], rowCap: Int) -> [Int] {
        notes.indices.map { index in
            var rank = 0
            for other in notes.indices
            where other != index && overlaps(notes[index], notes[other])
                && ranksBelow(notes, other, index)
            {
                rank += 1
            }
            return min(max(rank, 0), rowCap - 1)
        }
    }

    /// True when note `lhs` sorts below note `rhs`: lower pitch, then earlier start, then lower
    /// array index. The index tiebreak is what makes the ordering total, hence deterministic.
    private static func ranksBelow(_ notes: [Note], _ lhs: Int, _ rhs: Int) -> Bool {
        let a = notes[lhs]
        let b = notes[rhs]
        if a.pitch != b.pitch { return a.pitch < b.pitch }
        if a.start != b.start { return a.start < b.start }
        return lhs < rhs
    }

    private static func overlaps(_ a: Note, _ b: Note) -> Bool {
        a.start < b.end && b.start < a.end
    }

    // MARK: - Clustering

    /// Greedy online agglomeration over timbre vectors, in time order: join the nearest centroid
    /// within threshold, else open a new cluster while under the cap, else join the nearest anyway.
    /// Returns cluster row per note (nil for notes without timbre), numbered by ascending median
    /// pitch so Voice 1 stays the lowest part.
    private static func clusterRows(_ notes: [Note], rowCap: Int) -> [Int?] {
        // Explicit sort keys, never dictionary order: Swift Dictionary iteration is unstable.
        let ordered = notes.indices
            .filter { (notes[$0].timbre?.isEmpty == false) }
            .sorted {
                if notes[$0].start != notes[$1].start { return notes[$0].start < notes[$1].start }
                return $0 < $1
            }

        var centroids: [[Float]] = []
        var counts: [Int] = []
        var members: [[Int]] = []
        var clusterOf = [Int?](repeating: nil, count: notes.count)

        for index in ordered {
            let vector = normalized(notes[index].timbre ?? [])
            guard !vector.isEmpty else { continue }

            var best = -1
            var bestDistance = Float.greatestFiniteMagnitude
            for cluster in centroids.indices {
                let distance = cosineDistance(vector, centroids[cluster])
                if distance < bestDistance {
                    bestDistance = distance
                    best = cluster
                }
            }

            let target: Int
            if best >= 0 && bestDistance <= timbreDistanceThreshold {
                target = best
            } else if centroids.count < rowCap {
                centroids.append(vector)
                counts.append(0)
                members.append([])
                target = centroids.count - 1
            } else {
                target = best
            }

            // Running mean, re-normalized so the centroid stays a unit vector.
            let n = Float(counts[target])
            var mean = centroids[target]
            if counts[target] > 0 {
                for element in mean.indices where element < vector.count {
                    mean[element] = (mean[element] * n + vector[element]) / (n + 1)
                }
            } else {
                mean = vector
            }
            centroids[target] = normalized(mean)
            counts[target] += 1
            members[target].append(index)
            clusterOf[index] = target
        }

        // Rank clusters by median pitch ascending; ties by first-seen order for determinism.
        let ranking = centroids.indices
            .sorted {
                let a = medianPitch(members[$0], notes)
                let b = medianPitch(members[$1], notes)
                if a != b { return a < b }
                return $0 < $1
            }
        var rowForCluster = [Int](repeating: 0, count: centroids.count)
        for (row, cluster) in ranking.enumerated() { rowForCluster[cluster] = row }

        return clusterOf.map { $0.map { min(rowForCluster[$0], rowCap - 1) } }
    }

    private static func medianPitch(_ indices: [Int], _ notes: [Note]) -> Double {
        guard !indices.isEmpty else { return .greatestFiniteMagnitude }
        let pitches = indices.map { notes[$0].pitch }.sorted()
        let middle = pitches.count / 2
        if pitches.count % 2 == 1 { return Double(pitches[middle]) }
        return Double(pitches[middle - 1] + pitches[middle]) / 2
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return [] }
        return vector.map { $0 / norm }
    }

    /// Both inputs are unit-L2, so cosine distance is `1 - dot`. Mismatched lengths mean the
    /// envelopes are not comparable at all: treat them as maximally distant.
    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0
        for index in a.indices { dot += a[index] * b[index] }
        return 1 - max(-1, min(1, dot))
    }

    // MARK: - Collisions

    /// Two notes sounding at the same instant must never share a row. Notes are placed in time
    /// order (then pitch, then index) so a note already sounding keeps its row and the newcomer
    /// moves.
    private static func resolveCollisions(
        _ notes: [Note],
        desired: [Int],
        fallback: [Int],
        rowCap: Int
    ) -> [Int] {
        let order = notes.indices.sorted {
            if notes[$0].start != notes[$1].start { return notes[$0].start < notes[$1].start }
            if notes[$0].pitch != notes[$1].pitch { return notes[$0].pitch < notes[$1].pitch }
            return $0 < $1
        }

        var assigned = [Int](repeating: 0, count: notes.count)
        var placed: [Int] = []

        for index in order {
            var taken = Set<Int>()
            for other in placed where overlaps(notes[index], notes[other]) {
                taken.insert(assigned[other])
            }

            let want = min(max(desired[index], 0), rowCap - 1)
            if taken.contains(want) {
                // Nearest free row; ties resolved toward the note's pitch rank so displaced notes
                // still stack low-to-high.
                let free = (0..<rowCap).filter { !taken.contains($0) }
                let pick = free.min {
                    let da = (abs($0 - want), abs($0 - fallback[index]), $0)
                    let db = (abs($1 - want), abs($1 - fallback[index]), $1)
                    return da < db
                }
                // Every row is already occupied: overflow onto the desired row.
                assigned[index] = pick ?? want
            } else {
                assigned[index] = want
            }
            placed.append(index)
        }

        return assigned
    }
}
