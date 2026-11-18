import Foundation
import QuartzCore

/// A file's modification time (seconds; 0 when it isn't there). Caches keyed by path + stamp ask on every frame.
/// While `hold` is on (the editor, during playback) an answer is remembered for half a second, so playing costs one
/// `stat` per file per half second instead of several per frame. Off (the default: renders, exports, the MCP
/// server, the paused editor) every call looks at the file, so a rewritten asset shows in the very next frame.
public enum FileStamp {
    public static var hold = false {
        didSet { if !hold { reset() } }
    }

    private static let lock = NSLock()
    private static var seen: [String: (stamp: Double, at: CFTimeInterval)] = [:]

    public static func of(_ path: String) -> Double {
        func stat() -> Double {
            ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?
                .timeIntervalSince1970 ?? 0
        }
        guard hold else { return stat() }
        let now = CACurrentMediaTime()
        lock.lock()
        if let s = seen[path], now - s.at < 0.5 { lock.unlock(); return s.stamp }
        lock.unlock()
        let stamp = stat()
        lock.lock()
        if seen.count > 4096 { seen.removeAll(keepingCapacity: true) }
        seen[path] = (stamp, now)
        lock.unlock()
        return stamp
    }

    /// Forget what was seen (after writing a file that must be picked up at once).
    public static func reset() { lock.lock(); seen.removeAll(keepingCapacity: true); lock.unlock() }
}
