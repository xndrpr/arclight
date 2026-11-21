import ArclightCore
import Foundation

/// Where a property lives: on a layer, or on the scene itself (background, camera, fog, post, duration…).
enum PropHost: Hashable {
    case node(String)
    case scene

    /// Special selection ids set by the layer list for scene objects.
    static let cameraSelection = "@camera"
    static let lookSelection = "@look"
}

extension Scene {
    /// Reads a prop from a host. Scene meta fields (duration, size, fps, name) are exposed as constants.
    func prop(_ host: PropHost, _ name: String) -> Prop? {
        switch host {
        case .node(let id): return node(id)?.props[name]
        case .scene:
            switch name {
            case "background": return background
            case "camera": return camera
            case "fog": return fog
            case "post": return post
            case "duration": return .value(.number(duration))
            case "fps": return fps.map { .value(.number($0)) }
            case "size": return size.map { .value(.array($0.map { .number(Double($0)) })) }
            case "loudness": return loudness.map { .value(.number($0)) }
            // Audio and sound clips are plain values: shown and edited as their JSON.
            case "audio": return audio.flatMap(Self.json).map { .value($0) }
            case "sounds": return sounds.flatMap(Self.json).map { .value($0) }
            default: return nil
            }
        }
    }

    mutating func setProp(_ host: PropHost, _ name: String, _ p: Prop?) {
        switch host {
        case .node(let id):
            guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
            nodes[i].props[name] = p
        case .scene:
            let v = p.flatMap { if case .value(let v) = $0 { return v } else { return nil } }
            switch name {
            case "background": background = p
            case "camera": camera = p
            case "fog": fog = p
            case "post": post = p
            case "duration": if let d = v?.double, d > 0 { duration = d }
            case "fps": fps = v?.double.flatMap { $0 > 0 ? $0 : nil }
            case "size":
                if let d = v?.doubles, d.count == 2, d.allSatisfy({ $0 >= 16 }) {
                    size = d.map { Int($0) }
                } else if p == nil {
                    size = nil
                }
            case "loudness": loudness = v?.double.map { min(-6, max(-40, $0)) }
            case "audio":
                if let v, let a = try? v.decoded(as: AudioRef.self), !a.src.isEmpty { audio = a } else if p == nil { audio = nil }
            case "sounds":
                if let v, let list = try? v.decoded(as: [AudioRef].self) {
                    let kept = list.filter { !$0.src.isEmpty }
                    sounds = kept.isEmpty ? nil : kept
                } else if p == nil {
                    sounds = nil
                }
            default: break
            }
        }
    }
}

extension Scene {
    /// The last value converted for each type is remembered: the inspector reads the sound list once per clip row
    /// and field, and converting a hundred clips each time made a scene's inspector take a quarter of a second.
    fileprivate static func json<T: Encodable & Equatable>(_ v: T) -> JSONValue? {
        let key = ObjectIdentifier(T.self)
        if let (old, j) = memoLock.withLock({ jsonMemo[key] }), let old = old as? T, old == v { return j }
        let j = (try? JSONEncoder().encode(v)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        memoLock.withLock { jsonMemo[key] = (v, j) }
        return j
    }

    nonisolated(unsafe) private static var jsonMemo: [ObjectIdentifier: (Any, JSONValue?)] = [:]
    private static let memoLock = NSLock()
}

extension EditorDocument {
    /// Time the host's keyframes are measured in: node-local for layers, scene time for scene props.
    func localTime(_ host: PropHost) -> Double {
        if case .node(let id) = host { return time - (scene.node(id)?.start ?? 0) }
        return time
    }

    /// Scene time of a host-local time.
    func sceneTime(_ host: PropHost, local: Double) -> Double {
        if case .node(let id) = host { return local + (scene.node(id)?.start ?? 0) }
        return local
    }

    func rootProp(_ host: PropHost, _ name: String) -> Prop? { scene.prop(host, name) }

    /// Stored (token-preserving) value of a root prop at the playhead; expressions are evaluated.
    func currentValue(_ host: PropHost, _ name: String) -> JSONValue? {
        guard let p = rootProp(host, name) else { return nil }
        if let v = p.rawValue(at: localTime(host)) { return v }
        return renderer.evaluator.value(p, t: localTime(host), T: time, duration: scene.duration)
    }

    /// Writes `v` at `path` inside root prop `name` (empty path = the prop itself), keying at the playhead when
    /// the root prop is keyframed. `nil` removes.
    func write(_ host: PropHost, _ name: String, path: [String] = [], _ v: JSONValue?) {
        // The scene length is END itself: set it exactly like dragging END (frame-rounded, never auto-grown back
        // to the last key — scrubbing Duration below a keyframe used to snap straight back).
        if host == .scene, name == "duration", path.isEmpty {
            if let d = v?.double, d > 0 { setDuration(d) }
            return
        }
        let t = localTime(host)
        edit { s in
            let cur = s.prop(host, name)
            let next: Prop?
            if let cur {
                next = cur.setting(path: path, to: v, at: t)
            } else if let v {
                next = .value(JSONValue.null.setting(path: path, to: v))
            } else {
                next = nil
            }
            s.setProp(host, name, next)
        }
    }

    func setRootProp(_ host: PropHost, _ name: String, _ p: Prop?) { edit { $0.setProp(host, name, p) } }

    func keyHere(_ host: PropHost, _ name: String) -> Keyframe? {
        rootProp(host, name)?.key(at: localTime(host), fps: fps)
    }

    func toggleKey(_ host: PropHost, _ name: String) {
        guard let cur = currentValue(host, name) else { return }
        let t = localTime(host)
        edit { s in s.setProp(host, name, (s.prop(host, name) ?? .value(cur)).togglingKey(at: t, current: cur)) }
    }

    /// Removes all keyframes, keeping the value at the playhead.
    func clearAnimation(in host: PropHost, _ name: String) {
        guard let cur = currentValue(host, name) else { return }
        setRootProp(host, name, .value(cur))
    }

    func setEase(_ host: PropHost, _ name: String, _ e: Easing) {
        let t = localTime(host)
        edit { s in if let p = s.prop(host, name) { s.setProp(host, name, p.settingEase(e, at: t, fps: fps)) } }
    }

    /// Moves the playhead to the previous/next keyframe of a prop.
    func jumpKey(in host: PropHost, _ name: String, forward: Bool) {
        if case .node(let id) = host { jumpKey(forward: forward, node: id, prop: name); return }
        guard case .keys(let ks)? = rootProp(host, name) else { return }
        let eps = 0.5 / fps
        let target = forward ? ks.first { $0.t > time + eps } : ks.last { $0.t < time - eps }
        if let t = target?.t { playing = false; time = min(max(0, t), maxTime) }
    }

    /// Writes several props of a layer at once (one undo step), e.g. from an animation preset.
    func applyProps(_ id: String, _ props: [String: Prop]) {
        edit { s in
            guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return }
            for (k, p) in props { s.nodes[i].props[k] = p }
        }
    }

    /// Error message for an expression, or nil if it compiles and runs.
    func exprError(_ src: String) -> String? {
        if src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Empty expression" }
        return renderer.evaluator.expr.compileError(src)
    }
}
