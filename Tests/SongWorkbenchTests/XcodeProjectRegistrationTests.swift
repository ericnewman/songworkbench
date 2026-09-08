import XCTest

/// SwiftPM globs `Sources/`, Xcode does not: every file must be listed in project.pbxproj AND
/// wired into each target's Sources build phase. Without this test the package builds green while
/// Xcode fails — which is exactly how `SongBarGrid.swift` and `HarmonyDecodeResolution.swift`
/// reached Eric's machine unbuildable, and how `WaveformAnalyzer.swift` sat in the macOS target
/// but not the (since removed) iPad one.
final class XcodeProjectRegistrationTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SongWorkbenchTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private func projectFile() throws -> String {
        try String(
            contentsOf: Self.repo.appendingPathComponent("SongWorkbench.xcodeproj/project.pbxproj"),
            encoding: .utf8)
    }

    private func swiftFiles(in directory: String) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: Self.repo.appendingPathComponent(directory).path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
    }

    /// The filenames each `Sources` build phase actually compiles, keyed by phase id.
    private func sourcesPhases(_ pbxproj: String) -> [String: Set<String>] {
        let buildFile = try! NSRegularExpression(
            pattern: #"([0-9A-F]+) /\* ([^*]+?) in Sources \*/ = \{isa = PBXBuildFile"#)
        var nameForBuildFileID: [String: String] = [:]
        let whole = NSRange(pbxproj.startIndex..., in: pbxproj)
        for match in buildFile.matches(in: pbxproj, range: whole) {
            let id = String(pbxproj[Range(match.range(at: 1), in: pbxproj)!])
            nameForBuildFileID[id] = String(pbxproj[Range(match.range(at: 2), in: pbxproj)!])
        }

        let phase = try! NSRegularExpression(
            pattern: #"([0-9A-F]+) /\* Sources \*/ = \{\s*isa = PBXSourcesBuildPhase;"#
                + #".*?files = \((.*?)\);"#,
            options: .dotMatchesLineSeparators)
        let reference = try! NSRegularExpression(pattern: #"([0-9A-F]+) /\*"#)
        var phases: [String: Set<String>] = [:]
        for match in phase.matches(in: pbxproj, range: whole) {
            let id = String(pbxproj[Range(match.range(at: 1), in: pbxproj)!])
            let body = String(pbxproj[Range(match.range(at: 2), in: pbxproj)!])
            let ids = reference.matches(in: body, range: NSRange(body.startIndex..., in: body))
                .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
            phases[id] = Set(ids.compactMap { nameForBuildFileID[$0] })
        }
        return phases
    }

    func testEverySwiftFileHasAFileReferenceInTheXcodeProject() throws {
        let pbxproj = try projectFile()
        var unregistered: [String] = []
        for directory in ["Sources/SongWorkbench", "Tests/SongWorkbenchTests"] {
            for name in try swiftFiles(in: directory) where !pbxproj.contains(name) {
                unregistered.append("\(directory)/\(name)")
            }
        }
        XCTAssertEqual(
            unregistered, [],
            """
            These files build under SwiftPM but have no PBXFileReference, so Xcode will not \
            compile them. Add each to the file reference list, the group listing, and every \
            target's Sources build phase.
            """)
    }

    /// Every app target compiles every source file (generated `Tuist*` bundle accessors aside) —
    /// anything missing from a target is one the package tests can't see failing. There is one
    /// app target since iPad support was shelved (2026-09-08); the loop stays so a second target
    /// is covered the day one returns.
    func testEveryAppTargetCompilesEverySourceFile() throws {
        let pbxproj = try projectFile()
        let sources = Set(try swiftFiles(in: "Sources/SongWorkbench"))
        let appPhases = sourcesPhases(pbxproj).values
            .filter { !$0.contains("AnalysisDocumentTests.swift") }
        XCTAssertEqual(appPhases.count, 1, "Expected exactly the macOS app target")

        for phase in appPhases {
            let missing = sources.subtracting(phase).sorted()
                .filter { !$0.hasPrefix("Tuist") }
            XCTAssertEqual(
                missing, [],
                "An app target's Sources build phase is missing these files, so that target "
                    + "fails in Xcode while `swift build` passes.")
        }
    }
}
