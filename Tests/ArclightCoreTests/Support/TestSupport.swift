import AVFoundation
import Foundation
import Metal
import Testing

@testable import ArclightCore
@testable import ArclightEditor

// Shared test helpers. New tests use these instead of hand-rolled temp folders.

/// Whether this Mac has a usable Metal device. GitHub's macOS runners may have none. Set `ARCLIGHT_TEST_NO_METAL=1`
/// to run the suite as if there were none (only these helpers read it).
let hasMetal: Bool = {
    if ProcessInfo.processInfo.environment["ARCLIGHT_TEST_NO_METAL"] != nil { return false }
    guard let d = MTLCreateSystemDefaultDevice() else { return false }
    return d.makeCommandQueue() != nil
}()

extension Trait where Self == ConditionTrait {
    /// For tests and suites that create a `Renderer` or an `EditorDocument` (whose init creates one): skipped,
    /// with a message, when there is no Metal device.
    static var requiresMetal: Self { .enabled(if: hasMetal, "no Metal device (CI runner without GPU)") }
}

/// A project in a fresh temporary folder (`arclight-<label>-<uuid>.arclight`). Call `remove()` in a `defer`.
struct TempProject {
    let url: URL
    let store: ProjectStore

    init(_ label: String = "test", name: String = "t", scenes: [ArclightCore.Scene] = []) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-\(label)-\(UUID().uuidString).arclight")
        store = try ProjectStore.create(at: url, name: name)
        for s in scenes { try store.save(scene: s) }
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Settings domains kept in a fresh temporary folder instead of ~/Library/Preferences. A domain name that is an
/// absolute path is stored by CFPreferences as `<path>.plist`. Named domains can't be cleaned up: `removePersistentDomain`
/// empties one but leaves its file in ~/Library/Preferences, and `CFFIXED_USER_HOME` doesn't move settings (cfprefsd
/// uses the real home). Call `remove()` in a `defer`.
struct TempDefaults {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The domain name for `name`: a path inside `folder`.
    func domain(_ name: String) -> String { folder.appendingPathComponent(name).path }

    /// A `UserDefaults` that reads and writes only the domain `name`.
    func suite(_ name: String) throws -> UserDefaults { try #require(UserDefaults(suiteName: domain(name))) }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// An editor document on a temporary project holding `scene`. Remove the project when done.
func makeDoc(scene: ArclightCore.Scene) throws -> (doc: EditorDocument, project: TempProject) {
    let p = try TempProject("doc", scenes: [scene])
    return (try EditorDocument(url: p.url), p)
}

/// Writes a 440 Hz sine WAV (48 kHz) into the first channel; other channels are silent.
/// `amplitude` maps time in seconds to the sine's amplitude.
func tone(
    _ url: URL, seconds: Double = 2, channels: AVAudioChannelCount = 1, amplitude: (Double) -> Double = { _ in 0.5 }
) throws {
    let rate = 48000.0
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
    let n = AVAudioFrameCount(rate * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
    buf.frameLength = n
    for i in 0..<Int(n) {
        let t = Double(i) / rate
        buf.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * amplitude(t))
    }
    try f.write(from: buf)
}

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }
func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
