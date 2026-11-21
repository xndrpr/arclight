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
        // One `stat` call: FileManager's attributes also read extended attributes and build a dictionary, which was
        // 40 % of the viewer's CPU time per frame on a scene with dozens of assets.
        func modified() -> Double {
            var st = stat()
            guard stat(path, &st) == 0 else { return 0 }
            return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        }
        guard hold else { return modified() }
        let now = CACurrentMediaTime()
        lock.lock()
        if let s = seen[path], now - s.at < 0.5 { lock.unlock(); return s.stamp }
        lock.unlock()
        let stamp = modified()
        lock.lock()
        if seen.count > 4096 { seen.removeAll(keepingCapacity: true) }
        seen[path] = (stamp, now)
        lock.unlock()
        return stamp
    }

    /// Forget what was seen (after writing a file that must be picked up at once).
    public static func reset() { lock.lock(); seen.removeAll(keepingCapacity: true); lock.unlock() }
}
