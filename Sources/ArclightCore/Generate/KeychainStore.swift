import Foundation
import Security

/// API keys (image providers, the chat model provider), kept in the login Keychain (never in the project or
/// preferences). The editor and the MCP server are the same signed `arclight` binary, so both can read what Settings
/// saved. Keys in the environment win (agents and the CLI on machines without the key saved).
/// The service name predates the chat key and is kept so saved keys still work.
public enum KeychainStore {
    static let service = "app.arclight.image-providers"

    /// Tests swap this for an in-memory store so they never touch the real Keychain.
    nonisolated(unsafe) public static var backend: Backend = SystemKeychain() { didSet { cached = nil } }

    /// The Keychain's answers by account, remembered: the editor asks on every redraw of the AI bar, and a Keychain
    /// lookup costs about a millisecond. The setters refresh them.
    nonisolated(unsafe) private static var cached: [String: String?]?

    public protocol Backend {
        func read(_ account: String) -> String?
        func write(_ account: String, _ value: String?) throws
    }

    public static func falKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        key("fal", env: ["ARCLIGHT_FAL_KEY", "FAL_KEY"], environment: environment)
    }

    /// Saves (or with nil / empty, removes) the fal.ai key.
    public static func setFalKey(_ key: String?) throws { try set("fal", key) }

    /// The API key the in-app chat uses (Settings ▸ AI ▸ Chat).
    public static func chatKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        key("anthropic", env: ["ARCLIGHT_ANTHROPIC_KEY", "ANTHROPIC_API_KEY"], environment: environment)
    }

    /// Saves (or with nil / empty, removes) the chat API key.
    public static func setChatKey(_ key: String?) throws { try set("anthropic", key) }

    private static func key(_ account: String, env: [String], environment: [String: String]) -> String? {
        for k in env {
            if let v = environment[k]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
        }
        if let c = cached?[account] { return c }
        let v = backend.read(account)
        cached = (cached ?? [:]).merging([account: v]) { $1 }
        return v
    }

    private static func set(_ account: String, _ key: String?) throws {
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        cached = nil
        try backend.write(account, k?.isEmpty == false ? k : nil)
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
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else {
                return nil
            }
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
            add[kSecAttrLabel] = account == "fal" ? "Arclight image generation (fal)" : "Arclight chat (\(account))"
            let st = SecItemAdd(add as CFDictionary, nil)
            guard st == errSecSuccess else {
                throw ImageAIError.failed("couldn't save the key in the Keychain (\(st))")
            }
        }
    }
}
