import ArclightCore
import Foundation

/// Presence: which agent session is connected, published for the editor's top bar and AI panel.
extension MCPServer {
    func startPresence() {
        publishesPresence = true
        presence.project = store.map { Presence.key($0.url) }
        presence.projects = store.map { [Presence.key($0.url)] } ?? []
        publishPresence()
        // Clean exit on SIGTERM (the editor's Disconnect), SIGINT and SIGHUP: remove the presence file.
        let pid = presence.pid
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                Presence.remove(pid: pid); exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func publishPresence() {
        guard publishesPresence else { return }
        Presence.write(presence)
    }
}
