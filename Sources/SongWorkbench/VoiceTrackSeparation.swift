import AVFoundation
import Accelerate
import CryptoKit
import Foundation

/// Pulls one detected harmony voice out of a vocal stem with an F0-informed harmonic mask: per
/// STFT frame, keep the bins around each partial of the notes that voice sings, share bins with
/// any other voice sounding the same partial, and silence the rest (Eric, 2026-10-07: "if I only
/// wanted to hear voice 3").
///
/// ponytail: a mask, not a model. Unvoiced consonants and breaths carry no pitch and are lost;
/// unisons and octaves cannot be split. `docs/research/harmony-voice-separation-2026-10.md`
/// covers what a learned separator would add.
enum VoiceTrackRenderer {
    struct Note: Equatable, Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let midiNote: Int
    }

    static let fftSize = 4_096
    static let hop = 1_024
    /// Partials above this are mostly breath and sibilance, not the sung pitch.
    static let maximumPartialHz = 8_000.0
    /// Each partial's half-width as a share of its frequency: about ±50 cents, enough for vibrato.
    static let partialWidthRatio = 0.03
    /// Never narrower than this many bins either side, so low partials survive pitch drift.
    static let minimumHalfWidthBins = 1.5
    /// Notes are kept a little past their detected edges so onsets are not clipped.
    static let edgeMargin: TimeInterval = 0.03

    /// `samples` filtered to the partials of `keep`. A bin `compete` also claims is shared in
    /// proportion to each side's weight there, so a partial both voices sing is split, not owned.
    static func isolate(
        samples: [Float], sampleRate: Double, keep: [Note], compete: [Note]
    ) -> [Float] {
        guard !samples.isEmpty, !keep.isEmpty, sampleRate > 0 else {
            return [Float](repeating: 0, count: samples.count)
        }
        let n = fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Double(n)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: samples.count)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        // Padded so the first and last samples sit under a full window.
        let padded = [Float](repeating: 0, count: n) + samples + [Float](repeating: 0, count: n)
        var output = [Float](repeating: 0, count: padded.count)
        var norm = [Float](repeating: 0, count: padded.count)
        let binHz = sampleRate / Double(n)
        let sortedKeep = keep.sorted { $0.start < $1.start }
        let sortedCompete = compete.sorted { $0.start < $1.start }

        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var keepWeight = [Float](repeating: 0, count: half)
        var competeWeight = [Float](repeating: 0, count: half)
        // vDSP's real FFT doubles on the way in and scales by n on the way back.
        let roundTrip = 1 / Float(2 * n)

        var offset = 0
        while offset + n <= padded.count {
            if Task.isCancelled { break }
            let center = (Double(offset + half - n)) / sampleRate
            let keepNow = active(sortedKeep, at: center)
            if !keepNow.isEmpty {
                let competeNow = active(sortedCompete, at: center)
                fill(&keepWeight, notes: keepNow, binHz: binHz)
                fill(&competeWeight, notes: competeNow, binHz: binHz)
                padded.withUnsafeBufferPointer { source in
                    vDSP_vmul(
                        source.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(n))
                }
                real.withUnsafeMutableBufferPointer { realBuffer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                        frame.withUnsafeBufferPointer { input in
                            input.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: half
                            ) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        // DC and Nyquist (packed in [0]) are never a sung partial.
                        split.realp[0] = 0
                        split.imagp[0] = 0
                        for bin in 1..<half {
                            let mine = keepWeight[bin] * keepWeight[bin]
                            let mask =
                                mine > 0
                                ? mine / (mine + competeWeight[bin] * competeWeight[bin]) : 0
                            split.realp[bin] *= mask
                            split.imagp[bin] *= mask
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                        frame.withUnsafeMutableBufferPointer { out in
                            out.baseAddress!.withMemoryRebound(
                                to: DSPComplex.self, capacity: half
                            ) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half)) }
                        }
                    }
                }
                for i in 0..<n {
                    output[offset + i] += frame[i] * roundTrip * window[i]
                }
            }
            for i in 0..<n { norm[offset + i] += window[i] * window[i] }
            offset += hop
        }
        var result = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let w = norm[i + n]
            result[i] = w > 1e-6 ? output[i + n] / w : 0
        }
        return result
    }

    private static func active(_ notes: [Note], at time: TimeInterval) -> [Note] {
        // ponytail: linear scan per frame; index by start time if songs grow past ~10k notes.
        notes.filter { $0.start - edgeMargin <= time && time <= $0.end + edgeMargin }
    }

    /// Triangular weight around every partial of every note, the strongest where they overlap.
    private static func fill(_ weights: inout [Float], notes: [Note], binHz: Double) {
        for i in weights.indices { weights[i] = 0 }
        let half = weights.count
        for note in notes {
            let f0 = 440 * pow(2, Double(note.midiNote - 69) / 12)
            var harmonic = 1.0
            while harmonic * f0 < min(maximumPartialHz, binHz * Double(half - 1)) {
                let centre = harmonic * f0 / binHz
                let width = max(minimumHalfWidthBins, centre * partialWidthRatio)
                let low = max(1, Int((centre - width).rounded(.down)))
                let high = min(half - 1, Int((centre + width).rounded(.up)))
                if low <= high {
                    for bin in low...high {
                        let weight = Float(max(0, 1 - abs(Double(bin) - centre) / width))
                        weights[bin] = max(weights[bin], weight)
                    }
                }
                harmonic += 1
            }
        }
    }
}

/// Writes one audio track per detected harmony voice and registers it under Vocals as a muted
/// strip (Eric, 2026-10-07: ordinary strips that start muted, named Voice 1–4 like the Review
/// chart). Runs after the stem set is final; re-runs only when the harmony notes change.
enum VoiceTrackPass {
    static let versionTag = "voice-tracks-1"
    static let idPrefix = "vocals.voice."

    static func stemID(forVoice index: Int) -> StemID {
        StemID(rawValue: idPrefix + "\(index + 1)")
    }

    static func isVoiceTrack(_ id: StemID) -> Bool { id.rawValue.hasPrefix(idPrefix) }

    /// The tag a current set of voice assets carries in `producerID`.
    static func producerID(for notes: [VocalHarmonyObservation]) -> String {
        var hasher = SHA256()
        for note in notes {
            let line =
                "\(note.timestamp)|\(note.duration)|\(note.midiNote)|\(note.voiceIndex ?? -1)|"
                + "\(note.sourceID?.rawValue ?? "")\n"
            hasher.update(data: Data(line.utf8))
        }
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(versionTag)|\(digest)"
    }

    static func apply(to document: inout SongAnalysisDocument) {
        guard let manifest = document.stemSet?.resolved() else { return }
        let notes = document.vocalHarmonyNotes.filter { $0.voiceIndex != nil }
        let voices = Set(notes.compactMap(\.voiceIndex)).sorted()
        let producer = producerID(for: notes)
        let existing = manifest.assets.filter { isVoiceTrack($0.id) }
        let wanted = Set(voices.map(stemID(forVoice:)))
        if Set(existing.map(\.id)) == wanted,
            existing.allSatisfy({
                $0.producerID == producer
                    && FileManager.default.fileExists(atPath: $0.audioURL.path)
            })
        {
            return
        }
        var updated = StemSetManifest(
            descriptors: manifest.descriptors.filter { !isVoiceTrack($0.id) },
            assets: manifest.assets.filter { !isVoiceTrack($0.id) },
            recipeIdentity: manifest.recipeIdentity)
        defer { document.stemSet = StoredStemSetManifest(manifest: updated) }
        guard !voices.isEmpty,
            let vocalsURL = updated.assetsByID[StemKind.vocals.id]?.audioURL
        else { return }
        let directory = vocalsURL.deletingLastPathComponent()
            .appendingPathComponent("Derived/voices", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Each note is filtered out of the stem it was heard on.
        let sources = Dictionary(grouping: notes) { $0.sourceID ?? StemKind.vocals.id }
        var loaded: [StemID: ([Float], Double)] = [:]
        for source in sources.keys {
            guard let url = manifest.assetsByID[source]?.audioURL,
                let audio = try? MonoSampleLoader.load(url: url)
            else { continue }
            loaded[source] = audio
        }
        guard let length = loaded.values.map(\.0.count).max(),
            let sampleRate = loaded.values.first?.1
        else { return }

        var descriptors: [StemDescriptor] = []
        var assets: [StemAsset] = []
        for voice in voices {
            if Task.isCancelled { return }
            var track = [Float](repeating: 0, count: length)
            for (source, sourceNotes) in sources {
                guard let (samples, rate) = loaded[source] else { continue }
                let keep = sourceNotes.filter { $0.voiceIndex == voice }.map(note)
                guard !keep.isEmpty else { continue }
                let compete = sourceNotes.filter { $0.voiceIndex != voice }.map(note)
                let isolated = VoiceTrackRenderer.isolate(
                    samples: samples, sampleRate: rate, keep: keep, compete: compete)
                for i in 0..<min(isolated.count, length) { track[i] += isolated[i] }
            }
            let id = stemID(forVoice: voice)
            let url = directory.appendingPathComponent("\(id.rawValue).wav")
            guard (try? writeMono(track, sampleRate: sampleRate, to: url)) != nil else { continue }
            descriptors.append(
                StemDescriptor(
                    id: id, parentID: StemKind.vocals.id, role: .derived,
                    displayName: "Voice \(voice + 1)", order: 300 + voice))
            assets.append(StemAsset(id: id, audioURL: url, producerID: producer))
            if !document.stemMixer.hasState(for: id) {
                document.stemMixer.setMuted(true, for: id)
            }
        }
        updated = StemSetManifest(
            descriptors: StemSetManifest.mergingDescriptors(updated.descriptors, descriptors),
            assets: StemSetManifest.mergingAssets(updated.assets, assets),
            recipeIdentity: updated.recipeIdentity)
    }

    private static func note(_ observation: VocalHarmonyObservation) -> VoiceTrackRenderer.Note {
        VoiceTrackRenderer.Note(
            start: observation.timestamp, end: observation.timestamp + observation.duration,
            midiNote: observation.midiNote)
    }

    private static func writeMono(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1,
                interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw WaveformAnalyzerError.unsupportedAudioFormat }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        try file.write(from: buffer)
    }
}
