import ArclightCore
import Foundation

/// Connected AI agents (`arclight mcp` sessions), read from their presence files once a second off the main
/// thread. Shared by every window; publishes only when something changed.
final class AgentMonitor: ObservableObject {
    static let shared = AgentMonitor()

    @Published private(set) var agents: [AgentPresence] = []
    private let queue = DispatchQueue(label: "arclight.agents", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var faked = false

    private init() { start() }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            let a = Presence.agents()
            DispatchQueue.main.async {
                guard let self, !self.faked, a != self.agents else { return }
                self.agents = a
            }
        }
        t.resume()
        timer = t
    }

    /// Snapshots/tests: show these agents and stop reading the real folder.
    func fake(_ a: [AgentPresence]) {
        faked = true
        timer?.cancel(); timer = nil
        agents = a
    }

    /// Ends an agent's MCP session (SIGTERM to its server; the AI client sees the server stop).
    func disconnect(_ a: AgentPresence) {
        agents.removeAll { $0.pid == a.pid }
        guard !faked else { return }
        queue.async {
            if Presence.isArclightProcess(a.pid) { kill(a.pid, SIGTERM) }
            Presence.remove(pid: a.pid)
        }
    }
}
