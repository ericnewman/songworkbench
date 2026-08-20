import Foundation
import SwiftUI

/// Entry point: dispatches to the headless CLI when the first argument is a known subcommand,
/// otherwise launches the SwiftUI app. The check is by SUBCOMMAND NAME, not "any arguments",
/// because normal app launches carry flags too (Xcode passes -NSDocumentRevisionsDebugMode).
@main
enum SongWorkbenchMain {
    static func main() async {
        #if os(macOS)
            if let command = SongWorkbenchCLI.parse(Array(CommandLine.arguments.dropFirst())) {
                exit(await SongWorkbenchCLI.run(command))
            }
        #endif
        SongWorkbenchApp.main()
    }
}

#if os(macOS)
    /// Headless access to the analysis pipeline — the scripting seam under any future MCP
    /// wrapper. Deliberately never touches the app's project store (`projects.json`): it
    /// analyzes a standalone audio file and writes results beside it, so a CLI run can never
    /// race the GUI app's debounced saves.
    enum SongWorkbenchCLI {
        struct Command {
            var audioURL: URL
            var stages: Set<SongAnalysisStage>
            var mode: TranscriptionMode
            var outputDirectory: URL?
            var printChart: Bool
        }

        static let usage = """
            usage: SongWorkbench analyze <audio-file> [options]

            Runs the analysis pipeline headless and writes results beside the audio file
            (or into --out). Never touches the app's song library.

            options:
              --stages s1,s2   comma list of: separation,transcription,harmony,chordPro
                               (default: all four)
              --mode m         transcription mode: fastDraft | balancedDraft | accuracy
                               (default: accuracy)
              --out DIR        output directory (default: the audio file's directory)
              --print-chart    also print the generated ChordPro chart to stdout

            outputs: <name>.analysis.json (full document), <name>.cho (chart)
            """

        /// Returns nil when the arguments are not a CLI invocation (launch the GUI instead).
        static func parse(_ arguments: [String]) -> Command? {
            guard let first = arguments.first else { return nil }
            if first == "--help" || first == "help" {
                print(usage)
                exit(0)
            }
            guard first == "analyze" else { return nil }
            var command = Command(
                audioURL: URL(fileURLWithPath: ""),
                stages: Set(SongAnalysisStage.allCases),
                mode: .accuracy,
                outputDirectory: nil,
                printChart: false
            )
            var audioPath: String?
            var index = 1
            while index < arguments.count {
                let argument = arguments[index]
                switch argument {
                case "--stages":
                    index += 1
                    guard index < arguments.count else { return fail("--stages needs a value") }
                    var stages: Set<SongAnalysisStage> = []
                    for name in arguments[index].split(separator: ",") {
                        guard let stage = SongAnalysisStage(rawValue: String(name)) else {
                            return fail("unknown stage '\(name)'")
                        }
                        stages.insert(stage)
                    }
                    command.stages = stages
                case "--mode":
                    index += 1
                    guard index < arguments.count,
                        let mode = TranscriptionMode(rawValue: arguments[index])
                    else { return fail("--mode needs fastDraft|balancedDraft|accuracy") }
                    command.mode = mode
                case "--out":
                    index += 1
                    guard index < arguments.count else { return fail("--out needs a value") }
                    command.outputDirectory = URL(
                        fileURLWithPath: arguments[index], isDirectory: true)
                case "--print-chart":
                    command.printChart = true
                default:
                    guard audioPath == nil else { return fail("unexpected argument '\(argument)'") }
                    audioPath = argument
                }
                index += 1
            }
            guard let audioPath else { return fail("missing audio file") }
            command.audioURL = URL(fileURLWithPath: audioPath)
            return command
        }

        private static func fail(_ message: String) -> Command? {
            FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
            exit(2)
        }

        static func run(_ command: Command) async -> Int32 {
            guard FileManager.default.fileExists(atPath: command.audioURL.path) else {
                log("error: no file at \(command.audioURL.path)")
                return 1
            }
            let outputDirectory =
                command.outputDirectory ?? command.audioURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)

            // Same model store and analysis cache the app uses (read/create only — the cache is
            // content-addressed, so sharing it means a CLI run reuses the app's separations).
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
                .first!
            var factory = SongAnalysisPipelineFactory(
                modelPackageManager: ModelPackageManager(
                    directoryURL:
                        applicationSupport
                        .appendingPathComponent("SongWorkbench", isDirectory: true)
                        .appendingPathComponent("Models", isDirectory: true),
                    downloader: URLSessionModelArtifactDownloader()
                ),
                harmonyEngine: AudioFileAnalysisService(),
                cache: AnalysisResultDiskCache(
                    directoryURL:
                        caches
                        .appendingPathComponent("SongWorkbench", isDirectory: true)
                        .appendingPathComponent("Analysis", isDirectory: true))
            )
            factory.capabilityProfile = AnalysisCapabilityProfile.current
            factory.stemRefinementEngineFactory = .production

            do {
                let assembly = try await factory.makePipeline()
                let title = command.audioURL.deletingPathExtension().lastPathComponent
                let request = SongAnalysisPipelineRequest(
                    sourceURL: command.audioURL,
                    outputDirectory: outputDirectory,
                    title: title,
                    stages: command.stages,
                    transcriptionMode: command.mode,
                    existingDocument: SongAnalysisDocument()
                )
                log(
                    "analyzing \(title) — stages: \(command.stages.map(\.rawValue).sorted().joined(separator: ","))"
                )
                let result = try await assembly.pipeline.run(request) { progress in
                    log(
                        "[\(progress.completedStages)/\(progress.totalStages)] "
                            + "\(Int(progress.fractionCompleted * 100))% \(progress.message)")
                }
                if result.wasCancelled {
                    log("cancelled")
                    return 130
                }
                for (stage, record) in result.document.stageRecords
                where record.state == .failed {
                    log("stage \(stage.rawValue) FAILED: \(record.errorMessage ?? "unknown")")
                }

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let documentURL = outputDirectory.appendingPathComponent(
                    "\(title).analysis.json")
                try (try encoder.encode(result.document)).write(to: documentURL)
                log("wrote \(documentURL.path)")
                if !result.document.chordProSource.isEmpty {
                    let chartURL = outputDirectory.appendingPathComponent("\(title).cho")
                    try Data(result.document.chordProSource.utf8).write(to: chartURL)
                    log("wrote \(chartURL.path)")
                    if command.printChart { print(result.document.chordProSource) }
                }
                let failed = result.document.stageRecords.values.contains {
                    $0.state == .failed
                }
                return failed ? 1 : 0
            } catch {
                log("error: \(error.localizedDescription)")
                return 1
            }
        }

        private static func log(_ message: String) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
#endif
