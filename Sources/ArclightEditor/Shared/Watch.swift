import Foundation
import Observation

/// Calls `changed` on the main queue after the value `read` returns changes. Observation reports a change once,
/// so the watch re-arms itself each time; it stops when released. Main thread only.
final class Watch<T: Equatable>: @unchecked Sendable {
    private let read: () -> T
    private let changed: () -> Void
    private var last: T?

    init(_ read: @escaping () -> T, changed: @escaping () -> Void) {
        self.read = read
        self.changed = changed
        arm()
    }

    private func arm() {
        last = withObservationTracking(read) { [weak self] in DispatchQueue.main.async { self?.fire() } }
    }

    private func fire() {
        let old = last
        arm()
        if last != old { changed() }
    }
}
