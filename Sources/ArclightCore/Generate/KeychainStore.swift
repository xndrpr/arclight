import Foundation
import Security

/// API keys for image providers, kept in the login Keychain (never in the project or preferences). The editor and
/// the MCP server are the same signed `arclight` binary, so both can read what Settings saved.
/// `FAL_KEY` / `ARCLIGHT_FAL_KEY` in the environment win (agents and the CLI on machines without the key saved).
public enum KeychainStore {
    static let service = "app.arclight.image-providers"

    /// Tests swap this for an in-memory store so they never touch the real Keychain.
    nonisolated(unsafe) public static var backend: Backend = SystemKeychain()

    public protocol Backend {
        func read(_ account: String) -> String?
        func write(_ account: String, _ value: String?) throws
    }

    public static func falKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for k in ["ARCLIGHT_FAL_KEY", "FAL_KEY"] {
            if let v = environment[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        return backend.read("fal")
    }

    /// Saves (or with nil / empty, removes) the fal.ai key.
    public static func setFalKey(_ key: String?) throws {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        try backend.write("fal", k?.isEmpty == false ? k : nil)
    }

    /// The fal provider when a key is available.
    public static func falProvider(models: FalProvider.Models = ImageSettings.models) -> FalProvider? {
        falKey().map { FalProvider(key: $0, models: models) }
    }

    public struct SystemKeychain: Backend {
        public init() {}
        public func read(_ account: String) -> String? {
            let q: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: KeychainStore.service,
                kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }

        public func write(_ account: String, _ value: String?) throws {
            let q: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword, kSecAttrService: KeychainStore.service, kSecAttrAccount: account,
            ]
            SecItemDelete(q as CFDictionary)
            guard let value else { return }
            var add = q
            add[kSecValueData] = Data(value.utf8)
            add[kSecAttrLabel] = "Arclight image generation (\(account))"
            let st = SecItemAdd(add as CFDictionary, nil)
            guard st == errSecSuccess else { throw ImageAIError.failed("couldn't save the key in the Keychain (\(st))") }
        }
    }

    /// In-memory backend for tests.
    public final class MemoryBackend: Backend {
        public var values: [String: String] = [:]
        public init() {}
        public func read(_ account: String) -> String? { values[account] }
        public func write(_ account: String, _ value: String?) throws { values[account] = value }
    }
}

/// Non-secret image settings shared by the editor and the MCP server (UserDefaults suite `app.arclight.shared`
/// would need an app group; a small JSON file in Application Support works for both processes).
public enum ImageSettings {
    static var url: URL { AppPaths.support.appendingPathComponent("image-settings.json") }

    struct Stored: Codable { var models: FalProvider.Models?; var enabled: Bool? }

    nonisolated(unsafe) static var overrideURL: URL?

    static func read() -> Stored {
        JSONFile.read(Stored.self, from: overrideURL ?? url) ?? Stored()
    }

    static func write(_ s: Stored) {
        let u = overrideURL ?? url
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(s).write(to: u, options: .atomic)
    }

    public static var models: FalProvider.Models {
        get { read().models ?? FalProvider.Models() }
        set { var s = read(); s.models = newValue; write(s) }
    }

    /// Generation on/off switch in Settings (on by default; nothing runs without a key either way).
    public static var enabled: Bool {
        get { read().enabled ?? true }
        set { var s = read(); s.enabled = newValue; write(s) }
    }
}
