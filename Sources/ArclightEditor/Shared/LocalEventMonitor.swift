import AppKit

/// An `NSEvent` local monitor that is removed on `remove()` or deinit. The handler's result goes back to AppKit
/// unchanged: return nil for every event you handled. Never write `self?.handle(e) ?? e`: it turns "handled" (nil)
/// back into the event, which made Space beep and timeline gestures apply twice. Use
/// `{ [weak self] e in guard let self else { return e }; return self.handle(e) }`.
final class LocalEventMonitor {
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent) -> NSEvent?
    private var token: Any?

    init(_ mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        self.mask = mask
        self.handler = handler
    }

    var isInstalled: Bool { token != nil }

    func install() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    func remove() {
        guard let t = token else { return }
        NSEvent.removeMonitor(t)
        token = nil
    }

    deinit { remove() }
}
