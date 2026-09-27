import Foundation
#if canImport(Glibc)
import Glibc
#endif

#if canImport(Darwin)
/// A vnode dispatch source on Apple platforms.
typealias FileWatchSource = DispatchSourceFileSystemObject

/// Flags to open a file only to watch it.
let fileWatchOpenFlags = O_EVTONLY

/// Watches `fd` for writes, renames, deletes and attribute changes.
func makeFileWatchSource(
    fd: Int32,
    queue: DispatchQueue,
    onEvent: @escaping @Sendable () -> Void,
    onCancel: @escaping @Sendable () -> Void
) -> FileWatchSource {
    let src = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend, .rename, .delete, .attrib],
        queue: queue
    )
    src.setEventHandler { onEvent() }
    src.setCancelHandler { onCancel() }
    src.resume()
    return src
}
#else
/// Polls the descriptor's stat where dispatch has no vnode sources: size,
/// modification, status change or link count moving counts as an event.
final class FileWatchSource: @unchecked Sendable {
    static let interval: DispatchTimeInterval = .milliseconds(500)

    private struct Stamp: Equatable {
        var size: Int
        var mtime: Int
        var mtimeNs: Int
        var ctime: Int
        var ctimeNs: Int
        var links: Int
    }

    private let timer: DispatchSourceTimer
    /// Only touched on the timer's queue.
    private var last: Stamp?

    init(fd: Int32, queue: DispatchQueue, onEvent: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        last = Self.stamp(fd)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.stamp(fd)
            if now != self.last {
                self.last = now
                onEvent()
            }
        }
        timer.setCancelHandler { onCancel() }
        timer.resume()
    }

    func cancel() {
        timer.cancel()
    }

    private static func stamp(_ fd: Int32) -> Stamp? {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        return Stamp(
            size: Int(st.st_size),
            mtime: Int(st.st_mtim.tv_sec), mtimeNs: Int(st.st_mtim.tv_nsec),
            ctime: Int(st.st_ctim.tv_sec), ctimeNs: Int(st.st_ctim.tv_nsec),
            links: Int(st.st_nlink)
        )
    }
}

/// Flags to open a file only to watch it.
let fileWatchOpenFlags = O_RDONLY

/// Watches `fd` for writes, renames, deletes and attribute changes.
func makeFileWatchSource(
    fd: Int32,
    queue: DispatchQueue,
    onEvent: @escaping @Sendable () -> Void,
    onCancel: @escaping @Sendable () -> Void
) -> FileWatchSource {
    FileWatchSource(fd: fd, queue: queue, onEvent: onEvent, onCancel: onCancel)
}
#endif
