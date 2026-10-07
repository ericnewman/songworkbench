import Foundation

/// Runs one `ORTSession.run` on a thread that exits as soon as the call returns.
///
/// ONNX Runtime 1.24.2's KleidiAI convolution (`mlas/lib/kleidiai/convolve_kleidiai.cpp`, taken
/// on SME CPUs such as the M4) keeps a `thread_local` map of input indirection tables on the
/// CALLING thread, keyed on a hash of the input's first 16 floats. Every chunk with new audio
/// therefore adds one table per 3x3-or-larger convolution (8 bytes x output positions x kernel
/// taps: 36 MB for a 2048 x 256 layer) and nothing evicts them until that thread exits. Measured:
/// ~330 MB per karaoke chunk, ~107 MB per drum chunk, ~16 MB per six-stem chunk; the same input
/// twice adds nothing. No session or run option reaches that cache; thread exit does. Upstream
/// `main` dropped the data hash from the key, so delete this once the Swift package ships it.
enum ORTShortLivedThread {
    static func run<T>(_ body: @escaping () throws -> T) throws -> T {
        // The caller blocks until the thread signals, so nothing here is touched concurrently.
        nonisolated(unsafe) let body = body
        nonisolated(unsafe) var result: Result<T, Error>?
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try autoreleasepool(invoking: body) }
            finished.signal()
        }
        // The calling thread computes alongside ORT's intra-op pool; keep it from lagging them.
        thread.qualityOfService = .userInitiated
        thread.start()
        finished.wait()
        return try result!.get()
    }
}
