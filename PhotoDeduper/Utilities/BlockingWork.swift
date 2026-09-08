import Foundation

/// Runs synchronous, blocking work on a private Dispatch queue instead of on a
/// Swift-concurrency cooperative thread.
///
/// Why this exists: the cooperative thread pool is fixed-width (one thread per
/// core — 10 on this machine). Swift's runtime assumes async code never blocks
/// a cooperative thread; it only ever suspends. Calling a *synchronous* framework
/// API that waits on a semaphore (`VNImageRequestHandler.perform`,
/// `AVAssetImageGenerator.copyCGImage`, `CGImageSourceCreateThumbnailAtIndex`)
/// from inside an `async` function breaks that assumption: the thread is parked
/// in the kernel and cannot pick up any other task.
///
/// Once as many such calls are in flight as there are cores, the pool is fully
/// consumed and *nothing* async can run any more — not the next photo, not the
/// progress update, not even the scan's own watchdog `Task.sleep`. That is a
/// hard deadlock, and it is exactly what pinned the scan at
/// "Scoring quality (25/4381)…": a `sample` of the wedged process showed all ten
/// cooperative threads stopped inside `FaceAnalyzer.analyze` →
/// `-[VNImageRequestHandler performRequests:]` → `semaphore_wait_trap`.
///
/// `Task.detached` does NOT help — detached tasks run on the same cooperative
/// pool. A real Dispatch queue does: its threads are not the pool's, so blocking
/// them starves nothing.
enum BlockingWork {
    /// Concurrent, user-initiated. Callers already bound how many items they
    /// evaluate at once (see `PhotoScorer.evaluateGroup(maxConcurrent:)`), so
    /// this never sees an unbounded fan-out.
    private static let queue = DispatchQueue(
        label: "com.photodeduper.blocking-work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Awaits `work` executed off the cooperative pool. The calling task
    /// suspends (freeing its cooperative thread) while a Dispatch worker blocks.
    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// One-shot continuation wrapper: whichever racer resumes first wins, later
/// resumes are dropped. Resuming a `CheckedContinuation` twice traps, and both
/// racers in `PhotoScorer`'s watchdog can finish, so the guard must be atomic.
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
