import Foundation
import Observation
import SwiftUI

/// Settings as views read them, tracked one key at a time: writing a setting redraws only the views that read that
/// key. (`@AppStorage` redrew every view holding one on any write to the defaults, AppKit's own window-frame saves
/// included, which redrew the whole editor for a tab switch or a new activity entry.)
@Observable final class PrefChanges {
    static let shared = PrefChanges()

    @ObservationIgnored private var seen: [String: NSObject] = [:]
    @ObservationIgnored private var versions: [String: Int] = [:]
    @ObservationIgnored private var token: NSObjectProtocol?

    private init() {
        // Writes that don't go through `Preference` (AppKit, the Settings window, `Pref.store.set`): bump the keys
        // that views read whose value really changed.
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.recheck() }
    }

    subscript(version key: String) -> Int { versions[key, default: 0] }

    func read(_ key: String) -> Any? {
        access(keyPath: \.[version: key])
        let v = Pref.store.object(forKey: key)
        seen[key] = v as? NSObject ?? NSNull()
        return v
    }

    func write(_ key: String, _ value: Any?) {
        Pref.store.set(value, forKey: key)
        seen[key] = value as? NSObject ?? NSNull()
        bump(key)
    }

    private func bump(_ key: String) { withMutation(keyPath: \.[version: key]) { versions[key, default: 0] += 1 } }

    private func recheck() {
        for (key, old) in seen {
            let now = Pref.store.object(forKey: key) as? NSObject ?? NSNull()
            if !now.isEqual(old) { seen[key] = now; bump(key) }
        }
    }
}

/// The values a `Preference` can hold.
protocol PreferenceValue {
    init?(stored: Any)
    var stored: Any { get }
}

extension Bool: PreferenceValue {
    init?(stored: Any) { guard let v = stored as? Bool else { return nil }; self = v }
    var stored: Any { self }
}

extension Int: PreferenceValue {
    init?(stored: Any) { guard let v = (stored as? NSNumber)?.intValue else { return nil }; self = v }
    var stored: Any { self }
}

extension Double: PreferenceValue {
    init?(stored: Any) { guard let v = (stored as? NSNumber)?.doubleValue else { return nil }; self = v }
    var stored: Any { self }
}

extension String: PreferenceValue {
    init?(stored: Any) { guard let v = stored as? String else { return nil }; self = v }
    var stored: Any { self }
}

/// `@AppStorage` for the editor's views, through `PrefChanges`: same key, same store (`Pref.store`), same values.
@propertyWrapper struct Preference<Value: PreferenceValue>: DynamicProperty {
    let key: String
    let defaultValue: Value

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        defaultValue = wrappedValue
    }

    var wrappedValue: Value {
        get { PrefChanges.shared.read(key).flatMap(Value.init(stored:)) ?? defaultValue }
        nonmutating set { PrefChanges.shared.write(key, newValue.stored) }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}
