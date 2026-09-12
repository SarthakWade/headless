import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class SupervisedHostOwnerMonitor: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var active = true

    public static func startIfRequested(
        onOwnerExit: @escaping @Sendable () -> Void
    ) -> SupervisedHostOwnerMonitor? {
        guard ProcessInfo.processInfo.environment["HEADLESS_SUPERVISED"] == "1" else {
            return nil
        }
        return SupervisedHostOwnerMonitor(onOwnerExit: onOwnerExit)
    }

    private init(onOwnerExit: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var byte: UInt8 = 0
            let count = withUnsafeMutableBytes(of: &byte) { buffer in
                read(STDIN_FILENO, buffer.baseAddress, 1)
            }
            if count >= 0 || errno != EINTR {
                self.stop()
                onOwnerExit()
            }
        }
        source.resume()
    }

    public func stop() {
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        active = false
        source.cancel()
        lock.unlock()
    }

    deinit { stop() }
}
