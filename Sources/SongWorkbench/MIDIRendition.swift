import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation
import SwiftUI

/// A stem played on a General MIDI instrument instead of its own audio (Eric, 2026-10-07:
/// "selecting either the actual track, or a MIDI instrument representation of the corresponding
/// Stem"). The notes come from analysis; the sound from the system GM bank.
///
/// Rendered offline to an audio file and played through the same player as the stem's audio, so
/// sync, pitch, tempo, meters and export behave exactly as they do for audio.
struct RenditionNote: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let midiNote: Int
    let velocity: UInt8
}

/// Which instrument a stem is played on, chosen per category in Settings.
enum MIDIInstrumentCategory: String, CaseIterable, Identifiable, Sendable {
    case vocals
    case voices
    case bass
    case guitar
    case piano
    case other
    case drums

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vocals: "Lead and backing vocals"
        case .voices: "Harmony voices"
        case .bass: "Bass"
        case .guitar: "Guitar"
        case .piano: "Piano"
        case .other: "Other"
        case .drums: "Drum pieces"
        }
    }

    var isDrumKit: Bool { self == .drums }

    /// Notes this instrument can plausibly play. Basic Pitch hears a bass stem's overtones as
    /// notes (Flip Flops: up to MIDI 77, F5); played on a bass they are stray high notes.
    var playableRange: ClosedRange<Int>? {
        self == .bass ? 23...64 : nil
    }

    func playable(_ notes: [RenditionNote]) -> [RenditionNote] {
        guard let range = playableRange else { return notes }
        return notes.filter { range.contains($0.midiNote) }
    }

    /// GM program (0-based) used until the user picks one; for drums, the GM kit program.
    var defaultProgram: Int {
        switch self {
        case .vocals: 52  // Choir Aahs
        case .voices: 53  // Voice Oohs
        case .bass: 33  // Electric Bass (finger)
        case .guitar: 25  // Acoustic Guitar (steel)
        case .piano: 0  // Acoustic Grand Piano
        case .other: 48  // String Ensemble 1
        case .drums: 0  // Standard kit
        }
    }

    /// The category a stem plays as, or nil when it has no MIDI rendition: the whole drums stem
    /// (only the separated drum pieces map to GM drums) and anything unknown.
    static func category(for id: StemID) -> MIDIInstrumentCategory? {
        if VoiceTrackPass.isVoiceTrack(id) { return .voices }
        if GMDrumMap.note(for: id) != nil { return .drums }
        let raw = id.rawValue
        func isKind(_ kind: StemKind) -> Bool {
            raw == kind.id.rawValue || raw.hasPrefix(kind.id.rawValue + ".")
        }
        if isKind(.vocals) { return .vocals }
        if isKind(.bass) { return .bass }
        if isKind(.guitar) { return .guitar }
        if isKind(.piano) { return .piano }
        if isKind(.other) { return .other }
        return nil
    }
}

/// The program chosen per category (UserDefaults, app-wide).
enum MIDIInstrumentPreferences {
    static func key(_ category: MIDIInstrumentCategory) -> String {
        "midiProgram.\(category.rawValue)"
    }

    static func program(for category: MIDIInstrumentCategory) -> Int {
        UserDefaults.standard.object(forKey: key(category)) as? Int ?? category.defaultProgram
    }
}

/// The separated drum pieces as GM percussion notes (channel 10 key map).
enum GMDrumMap {
    static func note(for id: StemID) -> Int? {
        switch id {
        case .drumKick: 36  // Bass Drum 1
        case .drumSnare: 38  // Acoustic Snare
        case .drumToms: 45  // Low Tom
        case .drumCymbals: 42  // Closed Hi-Hat: the cymbal heard most often
        default: nil
        }
    }

    /// One hit per detected attack, louder for stronger attacks.
    static func hits(samples: [Float], sampleRate: Double, note: Int) -> [RenditionNote] {
        let onsets = InstrumentOnsetDetector.onsets(samples: samples, sampleRate: sampleRate)
        let window = Int(sampleRate * 0.03)
        let peaks = onsets.map { time -> Float in
            let start = max(0, Int(time * sampleRate))
            let end = min(samples.count, start + window)
            return start < end ? samples[start..<end].map(abs).max() ?? 0 : 0
        }
        let loudest = max(peaks.max() ?? 1, 1e-6)
        return zip(onsets, peaks).map { time, peak in
            RenditionNote(
                start: time, end: time + 0.1, midiNote: note,
                velocity: UInt8(max(30, min(127, Int(127 * (peak / loudest).squareRoot())))))
        }
    }
}

/// The 128 General MIDI melodic program names and the GM2 drum kits, for the Settings pickers.
enum GeneralMIDI {
    static let programNames: [String] = [
        "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano",
        "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet", "Celesta",
        "Glockenspiel",
        "Music Box", "Vibraphone", "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ", "Reed Organ",
        "Accordion", "Harmonica", "Tango Accordion", "Acoustic Guitar (nylon)",
        "Acoustic Guitar (steel)", "Electric Guitar (jazz)", "Electric Guitar (clean)",
        "Electric Guitar (muted)", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
        "Acoustic Bass", "Electric Bass (finger)", "Electric Bass (pick)", "Fretless Bass",
        "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2", "Violin", "Viola", "Cello",
        "Contrabass", "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
        "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2",
        "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit", "Trumpet", "Trombone", "Tuba",
        "Muted Trumpet", "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax", "Oboe", "English Horn", "Bassoon",
        "Clarinet", "Piccolo", "Flute", "Recorder", "Pan Flute", "Blown Bottle", "Shakuhachi",
        "Whistle", "Ocarina", "Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)",
        "Lead 4 (chiff)", "Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)",
        "Lead 8 (bass + lead)", "Pad 1 (new age)", "Pad 2 (warm)", "Pad 3 (polysynth)",
        "Pad 4 (choir)", "Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
        "FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)",
        "FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)", "Sitar", "Banjo",
        "Shamisen", "Koto", "Kalimba", "Bagpipe", "Fiddle", "Shanai", "Tinkle Bell", "Agogo",
        "Steel Drums", "Woodblock", "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
        "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet", "Telephone Ring",
        "Helicopter", "Applause", "Gunshot",
    ]

    static let drumKits: [(program: Int, name: String)] = [
        (0, "Standard"), (8, "Room"), (16, "Power"), (24, "Electronic"), (25, "TR-808"),
        (32, "Jazz"), (40, "Brush"), (48, "Orchestra"),
    ]

    static func name(program: Int, drums: Bool) -> String {
        if drums { return drumKits.first { $0.program == program }?.name ?? "Kit \(program)" }
        return programNames.indices.contains(program) ? programNames[program] : "Program \(program)"
    }
}

/// Renders notes on a GM instrument to a stereo audio file, offline and faster than real time.
enum MIDIRenditionRenderer {
    static let soundBankURL = URL(
        fileURLWithPath:
            "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")
    /// Renders at the stem's own rate so the rendition lines up sample for sample.
    static func sampleRate(of url: URL) -> Double {
        (try? AVAudioFile(forReading: url).processingFormat.sampleRate) ?? 44_100
    }

    /// MIDI events land on chunk boundaries: 256 frames is under 6 ms at 44.1 kHz.
    static let chunkFrames: AVAudioFrameCount = 256

    static func render(
        notes: [RenditionNote], program: Int, drumKit: Bool, duration: TimeInterval,
        sampleRate: Double, to url: URL
    ) throws {
        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        else { throw WaveformAnalyzerError.unsupportedAudioFormat }
        engine.connect(sampler, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        try engine.start()
        defer { engine.stop() }
        try sampler.loadSoundBankInstrument(
            at: soundBankURL, program: UInt8(clamping: program),
            bankMSB: UInt8(
                drumKit ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB),
            bankLSB: UInt8(kAUSampler_DefaultBankLSB))

        // Note-ons and note-offs in time order; offs first at a tie so a repeated note restarts.
        let events =
            notes.flatMap { note in
                [(note.start, true, note), (max(note.end, note.start + 0.02), false, note)]
            }
            .sorted { ($0.0, $0.1 ? 1 : 0) < ($1.0, $1.1 ? 1 : 0) }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
            interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }
        let totalFrames = AVAudioFramePosition(duration * sampleRate)
        var next = 0
        while engine.manualRenderingSampleTime < totalFrames {
            if Task.isCancelled { throw CancellationError() }
            let now = Double(engine.manualRenderingSampleTime) / sampleRate
            while next < events.count, events[next].0 <= now {
                let (_, isOn, note) = events[next]
                let key = UInt8(clamping: note.midiNote)
                if isOn {
                    sampler.startNote(key, withVelocity: note.velocity, onChannel: 0)
                } else {
                    sampler.stopNote(key, onChannel: 0)
                }
                next += 1
            }
            let frames = AVAudioFrameCount(
                min(
                    AVAudioFramePosition(chunkFrames),
                    totalFrames - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            guard status == .success else { break }
            try file.write(from: buffer)
        }
    }
}

/// The notes a stem's rendition plays, and the cached rendition file for the current choice.
enum MIDIRenditionSource {
    static let versionTag = "midi-rendition-1"

    /// Notes for `id`, from what analysis already stored. Pitched stems without stored note
    /// events return nil; `transcribe` fills those in on demand.
    static func storedNotes(for id: StemID, in document: SongAnalysisDocument) -> [RenditionNote]? {
        if VoiceTrackPass.isVoiceTrack(id) {
            let voice = Int(id.rawValue.dropFirst(VoiceTrackPass.idPrefix.count)).map { $0 - 1 }
            let notes = document.vocalHarmonyNotes.filter { $0.voiceIndex == voice }
            return notes.map {
                RenditionNote(
                    start: $0.timestamp, end: $0.timestamp + $0.duration, midiNote: $0.midiNote,
                    velocity: UInt8(max(40, min(127, Int(127 * $0.confidence.squareRoot())))))
            }
        }
        guard let events = document.noteEvents?.first(where: { $0.stemID == id })?.events else {
            return nil
        }
        return events.map {
            RenditionNote(
                start: $0.onset, end: $0.offset, midiNote: $0.midiNote,
                velocity: UInt8(max(40, min(127, Int(127 * $0.confidence.squareRoot())))))
        }
    }

    /// Notes heard in the stem's own audio: GM drum hits for a drum piece, Basic Pitch notes for
    /// a pitched stem (also returned as a timeline to store on the document).
    static func transcribe(id: StemID, audioURL: URL) throws -> (
        notes: [RenditionNote], timeline: NoteEventTimeline?
    ) {
        let (samples, rate) = try MonoSampleLoader.load(url: audioURL)
        if let drum = GMDrumMap.note(for: id) {
            return (GMDrumMap.hits(samples: samples, sampleRate: rate, note: drum), nil)
        }
        guard let transcriber = BasicPitchNoteTranscriber.shared else {
            throw WaveformAnalyzerError.unsupportedAudioFormat
        }
        let events = try transcriber.transcribe(samples: samples, sampleRate: rate)
        let timeline = NoteEventTimeline(stemID: id, events: events)
        return (
            events.map {
                RenditionNote(
                    start: $0.onset, end: $0.offset, midiNote: $0.midiNote,
                    velocity: UInt8(max(40, min(127, Int(127 * $0.confidence.squareRoot())))))
            }, timeline
        )
    }

    /// Where the rendition of `notes` on `program` is cached, beside the stem's audio.
    static func cacheURL(
        for id: StemID, stemAudio: URL, notes: [RenditionNote], program: Int
    ) -> URL {
        var hasher = SHA256()
        hasher.update(data: Data("\(versionTag)|\(id.rawValue)|\(program)\n".utf8))
        for note in notes {
            hasher.update(
                data: Data("\(note.start)|\(note.end)|\(note.midiNote)|\(note.velocity)\n".utf8))
        }
        let digest = hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        return stemAudio.deletingLastPathComponent()
            .appendingPathComponent("Derived/midi", isDirectory: true)
            .appendingPathComponent("\(id.rawValue)-\(digest).wav")
    }
}

/// Settings tab: which GM instrument each track type plays when its strip is switched to MIDI.
struct MIDIInstrumentSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(MIDIInstrumentCategory.allCases) { category in
                    MIDIInstrumentPicker(category: category) { model.prepareMIDIRenditions() }
                }
            } footer: {
                Text(
                    "Switch a Stem Mix strip to MIDI with its ♪ button. Drum pieces need "
                        + "multi-track drums; pitched stems are transcribed the first time."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = model.midiRenditionError {
                Text(error).font(.caption).foregroundStyle(Color.swCoral)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
    }
}

private struct MIDIInstrumentPicker: View {
    let category: MIDIInstrumentCategory
    let changed: () -> Void
    @AppStorage private var program: Int

    init(category: MIDIInstrumentCategory, changed: @escaping () -> Void) {
        self.category = category
        self.changed = changed
        _program = AppStorage(
            wrappedValue: category.defaultProgram, MIDIInstrumentPreferences.key(category))
    }

    var body: some View {
        Picker(category.title, selection: $program) {
            if category.isDrumKit {
                ForEach(GeneralMIDI.drumKits, id: \.program) { kit in
                    Text(kit.name).tag(kit.program)
                }
            } else {
                ForEach(GeneralMIDI.programNames.indices, id: \.self) { index in
                    Text("\(index + 1). \(GeneralMIDI.programNames[index])").tag(index)
                }
            }
        }
        .onChange(of: program) { _, _ in changed() }
    }
}
