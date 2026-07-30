import Foundation
import OnnxRuntimeBindings
import XCTest

@testable import SongWorkbench

/// Probes an unfamiliar ONNX artifact's input/output contract before any integration work.
///
/// The existing stem engines assume a waveform contract (stereo samples in, N sources out) via
/// `StemChunkPredicting`. A model that instead expects a spectrogram needs an inverse STFT that
/// this codebase does not have, so the contract must be established BEFORE committing to a
/// refiner implementation. Skipped unless `SW_PROBE_MODEL` points at a model.
final class KaraokeModelProbeTests: XCTestCase {
    func testProbeModelIO() throws {
        guard let path = ProcessInfo.processInfo.environment["SW_PROBE_MODEL"] else {
            throw XCTSkip("set SW_PROBE_MODEL to probe an ONNX artifact's I/O contract")
        }
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        let session = try ORTSession(
            env: environment, modelPath: path, sessionOptions: options)

        let inputs = try session.inputNames()
        let outputs = try session.outputNames()
        print("probe_input_names=\(inputs.joined(separator: ","))")
        print("probe_output_names=\(outputs.joined(separator: ","))")

        // ORT reports the expected rank and dimensions in its error text when handed a
        // deliberately wrong shape, which is the cheapest way to read the contract without a
        // Python onnx dependency.
        guard let firstInput = inputs.first else { return XCTFail("model exposes no inputs") }
        let probe = NSMutableData(length: 2 * 1000 * MemoryLayout<Float>.size)!
        do {
            let value = try ORTValue(
                tensorData: probe, elementType: .float, shape: [1, 2, 1000])
            _ = try session.run(
                withInputs: [firstInput: value], outputNames: Set(outputs), runOptions: nil)
            print("probe_result=waveform_shape_1x2x1000_ACCEPTED")
        } catch {
            print("probe_rejected_waveform_shape=\(error.localizedDescription)")
        }

        // Rank 4 confirmed above; now pin the exact spectrogram dimensions the same way.
        for shape in [[1, 4, 64, 64], [1, 4, 2048, 256], [1, 4, 3072, 256]] {
            let floats = shape.reduce(1, *)
            let data = NSMutableData(length: floats * MemoryLayout<Float>.size)!
            do {
                let value = try ORTValue(
                    tensorData: data, elementType: .float,
                    shape: shape.map { NSNumber(value: $0) })
                let result = try session.run(
                    withInputs: [firstInput: value], outputNames: Set(outputs), runOptions: nil)
                let outShape =
                    (try? result[outputs.first ?? ""]?.tensorTypeAndShapeInfo().shape) ?? []
                print("probe_ACCEPTED_input=\(shape) output=\(outShape.map(\.intValue))")
            } catch {
                print("probe_rejected=\(shape) -> \(error.localizedDescription.prefix(160))")
            }
        }
    }
}
