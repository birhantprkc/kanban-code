import Foundation

#if !canImport(QuartzCore)
/// Monotonic seconds, as QuartzCore's function returns them on Apple platforms.
func CACurrentMediaTime() -> Double {
    ProcessInfo.processInfo.systemUptime
}
#endif

#if os(Linux)
import Glibc
#endif

extension Process {
    /// Starts the process with no signals blocked. On Linux a child inherits
    /// the spawning thread's signal mask, and dispatch worker threads block
    /// nearly every signal, so a child spawned from one ignores SIGTERM and
    /// SIGINT for good.
    public func runUnmasked() throws {
        #if os(Linux)
        var empty = sigset_t()
        var previous = sigset_t()
        sigemptyset(&empty)
        pthread_sigmask(SIG_SETMASK, &empty, &previous)
        defer { pthread_sigmask(SIG_SETMASK, &previous, nil) }
        #endif
        try run()
    }
}
