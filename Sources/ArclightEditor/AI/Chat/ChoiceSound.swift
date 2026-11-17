import AVFoundation
import ArclightCore
import SwiftUI

/// Plays the sound candidates of a choice card: each on its own, or in the scene's mix around where it would
/// sit. Previews are rendered off the main thread (the same mix and master limiter as an export) and kept for
/// the session.
final class ChoiceSoundPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    /// The preview that is playing or being prepared ("<option id>:alone" / "<option id>:scene").
    @Published private(set) var active: String?
    @Published private(set) var preparing = false
    @Published private(set) var failed: String?
    private var player: AVAudioPlayer?
    private var files: [String: URL] = [:]

    deinit { for u in files.values { try? FileManager.default.removeItem(at: u) } }

    func toggle(_ key: String, sound: ChatChoice.Sound, scene: Scene?, assets: URL?) {
        if active == key { stop(); return }
        stop()
        active = key
        failed = nil
        if let u = files[key] { start(u, key); return }
        preparing = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SceneMix.preview(sound.clip, in: scene, replace: sound.replace ?? [], assets: assets) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.preparing = false
                switch result {
                case .success(let u):
                    self.files[key] = u
                    if self.active == key { self.start(u, key) }
                case .failure(let e):
                    if self.active == key { self.active = nil }
                    self.failed = "\(e)"
                }
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        active = nil
    }

    private func start(_ url: URL, _ key: String) {
        guard let p = try? AVAudioPlayer(contentsOf: url) else { active = nil; failed = "can't play the preview"; return }
        p.delegate = self
        player = p
        p.play()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if self.player === player { self.active = nil; self.player = nil } }
    }
}

/// The play buttons under a sound option: the sound alone, and in the scene when the option names one.
struct ChoiceSoundButtons: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var player: ChoiceSoundPlayer
    let option: ChatChoice.Option
    let sound: ChatChoice.Sound
    /// Reads a scene by id (the card's cache of scenes on disk).
    let scene: (String) -> Scene?

    var body: some View {
        HStack(spacing: 6) {
            button("Sound", key: "\(option.id):alone", scene: nil, help: "Play this sound on its own")
            if let id = sound.scene {
                button("In the scene", key: "\(option.id):scene", scene: id, help: "Play it in the scene's mix, around where it would sit")
            }
            Spacer(minLength: 0)
        }
    }

    private func button(_ title: String, key: String, scene id: String?, help: String) -> some View {
        let on = player.active == key
        return Button {
            player.toggle(key, sound: sound, scene: id.flatMap(scene), assets: doc.assets)
        } label: {
            HStack(spacing: 4) {
                if on && player.preparing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: on ? "stop.fill" : "play.fill").font(.system(size: 8, weight: .bold))
                }
                Text(title).font(UI.small.weight(.medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on ? UI.ai.opacity(0.25) : UI.field))
            .overlay(Capsule().stroke(on ? UI.ai : UI.fieldBorder))
            .foregroundStyle(on ? UI.ai : UI.text)
        }
        .buttonStyle(.plain).cursor(.pointingHand).help(help)
    }
}
