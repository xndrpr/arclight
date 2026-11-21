import ArclightCore
import Foundation

/// Sound for agents: find free sounds and music on the web (Openverse), make motion sound effects on the device,
/// speak voiceovers (system voices, or ElevenLabs on fal.ai), generate effects and music (fal.ai), and analyse a
/// track for beats, hits and pauses to animate to. Every tool can place its result in a scene: as the reference
/// audio (music, voiceover) or as a sound clip at a time (`sounds`).
extension MCPServer {
    var soundLibrary: SoundLibrary { soundLibraryOverride ?? SoundLibrary() }

    func audioProvider() throws -> AudioProvider {
        if let p = audioProviderOverride { return p }
        guard ImageSettings.enabled, let p = KeychainStore.falProvider() else {
            throw ToolError(
                "AI audio needs the user's fal.ai key (Settings ▸ AI). Without it: sound_search (free sounds and music), sound_synth (motion effects) and voice_generate engine local (system voices) all work."
            )
        }
        return p
    }

    /// Tools that make or place sound: the first one called in a session carries the rules below.
    static let soundTools: Set<String> = [
        "sound_synth", "sound_search", "sound_import", "sound_generate", "voice_generate",
    ]

    /// The working rules for sound, in short, with the project's sound notes: appended once per session so an
    /// agent that never opened guide("sound") still works by them.
    func soundBrief() -> String {
        var s = """
            — Sound rules (shown once; guide("sound") has the rest) —
            You cannot hear: use the measurements each tool prints. Place by level (dB against the voice: effects −6…−12, \
            subtle −15…−20, music −12…−20 or duck 8–12), not by a guessed gain. Real effects exist on clips: lowpass, highpass, \
            reverb + space, pitch, rate, reverse, pan, duck. After every sound edit run mix_check and fix what it lists before \
            answering. A sound that is a matter of taste: make 2–4 candidates and let the user pick by ear (ask_choice stage \
            "sound" in the editor's chat) instead of placing a guess. A word with two readings (lower, noise, longer): ask. \
            Record the user's reactions with sound_notes.
            """
        if let url = store?.url, let notes = SoundNotes.read(url) { s += "\nThis project's sound notes:\n" + notes }
        return s
    }

    func transcriptProvider() throws -> TranscriptProvider {
        if let p = transcriptProviderOverride { return p }
        guard ImageSettings.enabled, let p = KeychainStore.falProvider() else {
            throw ToolError(
                "Word timings need the user's fal.ai key (Settings ▸ AI). Without it, audio_analyze {markers:\"phrases\"} gives the start of each sentence from the pauses."
            )
        }
        return p
    }

    /// Placement arguments shared by every tool that makes a sound.
    static let placeProps: [String: JSONValue] = [
        "scene": prop("string", "Scene to put it in (optional; without it the file just lands in assets/)"),
        "at": prop("number", "Scene time (s) where it starts (default 0)"),
        "as": prop(
            "string",
            "sound (a clip at 'at', mixed over everything; default for effects) or audio (the scene's reference track; default for music and voiceover)",
            extra: ["enum": ["sound", "audio"]]),
        "id": prop("string", "Sound clip id (default from the file name)"),
        "gain": prop("number", "Volume 0…4 (1 = as is; effects under music often sit at 0.5–0.8)"),
        "fadeIn": prop("number", "Fade-in (s)"), "fadeOut": prop("number", "Fade-out (s), ends where it stops"),
        "pitch": prop("number", "Pitch shift in semitones, −24…24 (−12 = an octave lower; length unchanged)"),
        "lowpass": prop("number", "Cut everything above this many Hz (softer, darker: 2000–5000 for a velvety sound)"),
        "highpass": prop("number", "Cut everything below this many Hz"),
        "reverb": prop("number", "Reverb 0…1 (0.15–0.35 is plenty)"),
        "space": prop("string", "Reverb space", extra: ["enum": .array(ClipFX.spaces.map { .string($0) })]),
        "pan": prop("number", "Stereo position −1 (left) … 1 (right)"),
        "level": prop(
            "number",
            "Instead of gain: how loud the clip should be against the scene audio, in dB (−9 = 9 dB under the voice or music; without scene audio, against −16 LUFS). The gain is worked out from the file's measured loudness. Effects under a voice: −6…−12; subtle: −15…−20."
        ),
    ]

    static func with(place extra: [String: JSONValue]) -> [String: JSONValue] {
        placeProps.merging(extra) { $1 }
    }

    /// Puts `asset` into the scene named by `a["scene"]`, if any. Returns report lines.
    func place(_ asset: String, _ a: [String: JSONValue], store s: ProjectStore, defaultAs: String) throws -> [String] {
        let measured = try? AudioDescriptors.measure(s.assetsURL.appendingPathComponent(asset))
        let head = measured.map { ["measured: " + $0.line] } ?? []
        guard let sid = a["scene"]?.string else {
            return head + [
                "not placed: add it with scene_apply {\"op\":\"sound\",\"src\":\"\(asset)\",\"offset\":t} or {\"op\":\"scene\",\"audio\":{\"src\":\"\(asset)\"}}"
            ]
        }
        let scene = try s.scene(sid)
        let at = a["at"]?.double ?? 0
        var fields: [String: JSONValue] = ["src": .string(asset)]
        if at != 0 { fields["offset"] = .number(at) }
        for k in [
            "gain", "fadeIn", "fadeOut", "length", "trim", "pitch", "lowpass", "highpass", "reverb", "space", "pan",
        ] { if let v = a[k], v != .null { fields[k] = v } }
        let mode = a["as"]?.string ?? defaultAs
        // Loudness of the scene audio as placed, to set and report the clip's level against it.
        let refLufs: Double? =
            mode == "audio"
            ? nil
            : scene.audio.flatMap { r in
                guard r.mute != true, let l = Loudness.integrated(file: SceneAudio.url(r, assets: s.assetsURL)),
                    l > -100
                else { return nil }
                return l + 20 * log10(max(r.gain ?? 1, 1e-6))
            }
        if let lv = a["level"]?.double, let m = measured, mode != "audio" {
            let g = pow(10, ((refLufs ?? -16) + lv - m.momentaryMax) / 20)
            fields["gain"] = .number((min(4, max(0, g)) * 1000).rounded() / 1000)
        }
        let op: JSONValue
        let label: String
        if mode == "audio" {
            op = .object(["op": "scene", "audio": .object(fields)])
            label = scene.audio.map { "scene audio (replaced \($0.src))" } ?? "scene audio"
        } else {
            let id = a["id"]?.string ?? SceneOps.uniqueSoundId(asset, in: scene.sounds ?? [])
            var f = fields
            f["op"] = "sound"; f["id"] = .string(id)
            op = .object(f)
            label = "sound \(id)"
        }
        let applied = try SceneOps.apply([op], to: scene)
        let saved = try saveValidated(applied.scene, store: s, expectedRev: scene.rev, summary: "add \(label)")
        var lines = head + ["\(label) at \(Format.number(at))s in \(sid) (rev \(saved.rev))"]
        if let m = measured, mode != "audio" {
            let g = fields["gain"]?.double ?? 1
            let lvl = ((m.momentaryMax + 20 * log10(max(g, 1e-6))) * 10).rounded() / 10
            var l = "level in the mix \(Format.number(lvl)) LUFS at gain \(Format.number(g))"
            if let r = refLufs {
                let d = ((lvl - r) * 10).rounded() / 10
                l +=
                    d >= 0
                    ? ": \(Format.number(d)) dB OVER the scene audio (\(Format.number((r * 10).rounded() / 10)) LUFS) — too loud for an effect under a voice"
                    : ": \(Format.number(-d)) dB under the scene audio (\(Format.number((r * 10).rounded() / 10)) LUFS)"
            }
            if g >= 3.99 { l += " (gain is at its limit of 4)" }
            lines.append(l + ". Run mix_check when the sound edits are done.")
        }
        if let info = SceneAudio.info(s.assetsURL.appendingPathComponent(asset)),
            at + info.duration > saved.duration + 0.05,
            mode == "audio"
        {
            lines.append(
                "note: the audio runs \(Format.number((info.duration * 10).rounded() / 10))s, the scene \(Format.number(saved.duration))s — it is cut at the scene end (fadeOut softens it), or lengthen the scene"
            )
        }
        return lines
    }

    /// The sound a tool reads: `sound` (a clip id) or the audio of `scene`, else the file `src` in assets/.
    func audioSource(_ a: [String: JSONValue], store s: ProjectStore) throws -> (ref: AudioRef, scene: Scene?) {
        guard let sid = a["scene"]?.string else { return (AudioRef(src: try a.str("src")), nil) }
        let sc = try s.scene(sid)
        if let id = a["sound"]?.string {
            guard let r = sc.sound(id) else { throw ToolError("no sound '\(id)' in \(sid)") }
            return (r, sc)
        }
        guard let r = sc.audio else {
            throw ToolError("\(sid) has no audio — pass sound (a clip id) or src (a file)")
        }
        return (r, sc)
    }

    func info(_ asset: String, store s: ProjectStore) -> String {
        guard let i = SceneAudio.info(s.assetsURL.appendingPathComponent(asset)) else { return asset }
        return "\(asset) (\(Format.number((i.duration * 100).rounded() / 100))s)"
    }

    func audioTools() -> [Tool] {
        [
            Tool(
                name: "sound_search",
                description:
                    "Search free sounds and music on the open web (Openverse: Freesound effects, Jamendo and Wikimedia music; Creative Commons). Free, no key. Defaults to licences that allow commercial use and edits. Search in English with plain words (\"whoosh\", \"glass break\", \"crowd cheer\", \"lofi hip hop\", \"cinematic piano\"). kind sfx = effects, music = tracks. Use max_seconds to keep effects short. Returns ids with title, length, creator and licence; CC BY needs a credit (sound_import writes it to assets/CREDITS.md). For simple motion sounds (whoosh, pop, click, riser, impact) sound_synth is faster and needs no credit.",
                schema: schema(
                    [
                        "query": prop("string", "What to find, in English"),
                        "kind": prop(
                            "string", "sfx, music or any (default)", extra: ["enum": ["sfx", "music", "any"]]),
                        "max_seconds": prop("number", "Longest length to accept (s)"),
                        "min_seconds": prop("number", "Shortest length to accept (s)"),
                        "limit": prop("integer", "Results, default 8 (max 20)"),
                        "any_license": prop(
                            "boolean", "Also show non-commercial / no-derivatives licences (only for private projects)"),
                        "measure": prop(
                            "boolean",
                            "Download the first 5 results and measure each (loudness, brightness, attack, tail, tone), so you choose by what they sound like, not by their titles. Slower; use it whenever the character matters."
                        ),
                    ], required: ["query"]),
                readOnly: true
            ) { [unowned self] a in
                let q = try a.str("query")
                let kind = SoundLibrary.Kind(rawValue: a["kind"]?.string ?? "any") ?? .any
                let limit = try SafeNumber.int(a["limit"]?.double ?? 8, "limit", in: 1...20)
                let lib = soundLibrary
                let maxS = a["max_seconds"]?.double, minS = a["min_seconds"]?.double
                let commercial = a["any_license"]?.bool != true
                let items = try blocking {
                    try await lib.search(
                        q, kind: kind, limit: limit, minSeconds: minS, maxSeconds: maxS, commercial: commercial)
                }
                guard !items.isEmpty else {
                    return text(
                        "nothing found for “\(q)”. Try other plain English words, drop the length limits, or make it: sound_synth (motion effects) or sound_generate (anything, fal.ai)."
                    )
                }
                var measures: [String: String] = [:]
                if a["measure"]?.bool == true {
                    for item in items.prefix(5) {
                        if let d = try? blocking({ try await lib.measure(item) }) { measures[item.id] = d.line }
                    }
                }
                return text(
                    items.map { $0.line + (measures[$0.id].map { "\n    measured: " + $0 } ?? "") }.joined(
                        separator: "\n")
                        + "\nsound_import {sound: id, scene, at} to use one (free; credits go to assets/CREDITS.md).")
            },

            Tool(
                name: "sound_import",
                description:
                    "Download a sound from sound_search into assets/ and, with scene, place it: as a sound clip at 'at' (default for effects) or as the scene's reference audio (as:\"audio\", for music). Writes the credit line to assets/CREDITS.md — tell the user when a sound needs a credit (CC BY). length/trim cut a part of a long file.",
                schema: schema(
                    MCPServer.with(place: [
                        "sound": prop("string", "Id from sound_search"),
                        "name": prop("string", "File name base (default from the title)"),
                        "trim": prop("number", "Seconds skipped at the start of the file"),
                        "length": prop("number", "Seconds played (default: to the end)"),
                    ]), required: ["sound"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try a.str("sound")
                guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                    throw ToolError("'\(id)' isn't a sound id from sound_search")
                }
                if let sid = a["scene"]?.string { _ = try s.scene(sid) }
                let lib = soundLibrary
                let name = a["name"]?.string
                let r = try blocking { try await lib.importSound(id, name: name, store: s) }
                var lines = [
                    "asset \(info(r.asset, store: s)) — “\(r.item.title)” from \(r.item.source), \(r.item.licenseName)"
                        + (r.item.needsCredit
                            ? "; credit needed: \(r.item.credit) (saved in assets/CREDITS.md)" : "; no credit needed")
                ]
                let music = (r.item.duration ?? 0) > 30
                lines += try place(r.asset, a, store: s, defaultAs: music ? "audio" : "sound")
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "sound_synth",
                description:
                    "Make a motion-graphics sound effect on the device: free, instant, no key, no credit. Presets: "
                    + SoundSynth.Preset.allCases.map { "\($0.rawValue) — \($0.about)" }.joined(separator: "; ")
                    + ". pitch shifts it in semitones (−24…24: lower = bigger and darker, higher = smaller/lighter); soft 0…1 rounds it off (use it when the user wants gentle, warm, velvety, not harsh); seed gives a different take of noisy ones. Use it for the hits that sell motion: a whoosh on each fast move, a pop when things appear, clicks for UI, a riser into a reveal with an impact on the hit. With scene it is placed as a sound clip at 'at' — line it up with the keyframe it accompanies (a whoosh centred on the move, an impact exactly on the landing frame).",
                schema: schema(
                    MCPServer.with(place: [
                        "preset": prop(
                            "string", "Which sound",
                            extra: ["enum": .array(SoundSynth.Preset.allCases.map { .string($0.rawValue) })]),
                        "duration": prop("number", "Seconds (default per preset)"),
                        "pitch": prop("number", "Semitones −24…24, default 0 (lower = bigger, darker)"),
                        "soft": prop(
                            "number",
                            "0…1: round the sound off — slower attack, highs rolled away. 0.4 takes the edge off, 0.8 is muffled and velvety."
                        ),
                        "seed": prop("integer", "Variation, default 1"),
                        "name": prop("string", "File name base (default the preset)"),
                    ]), required: ["preset"])
            ) { [unowned self] a in
                let s = try requireStore()
                guard let p = SoundSynth.Preset(rawValue: try a.str("preset")) else {
                    throw ToolError(
                        "unknown preset — one of " + SoundSynth.Preset.allCases.map(\.rawValue).joined(separator: ", "))
                }
                if let sid = a["scene"]?.string { _ = try s.scene(sid) }
                let d = try a["duration"]?.double.map { try SafeNumber.positive($0, "duration", max: 30) }
                let pitch = min(24, max(-24, a["pitch"]?.double ?? 0))
                let seed = UInt64(max(0, a["seed"]?.double ?? 1))
                let soft = min(1, max(0, a["soft"]?.double ?? 0))
                let asset = try SoundSynth.write(
                    p, duration: d, pitch: pitch, seed: seed, soft: soft, name: a["name"]?.string, store: s)
                var lines = ["asset \(info(asset, store: s)) — synthesised \(p.rawValue) (free)"]
                var placeArgs = a
                placeArgs["pitch"] = nil  // already baked into the synthesised file
                lines += try place(asset, placeArgs, store: s, defaultAs: "sound")
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "sound_generate",
                description:
                    "Generate a sound effect or music from a description with AI (fal.ai, the user's key, costs money). kind sfx: any effect — be concrete about source, material, space and length (\"heavy wooden door creaks open slowly in a stone hall\", \"sci-fi UI confirm beep, soft, short\"); duration 0.5–30 s; loop:true for seamless ambience. kind music: describe genre, mood, instruments, tempo and arc (\"uplifting corporate pop, 120 BPM, plucky synths and claps, builds to a big finish\"); duration in seconds (match the scene), instrumental by default. Try sound_search (free) first for common sounds and stock-style music, and sound_synth for basic motion effects. With scene: effects become sound clips at 'at', music the scene audio.",
                schema: schema(
                    MCPServer.with(place: [
                        "kind": prop("string", "sfx (default) or music", extra: ["enum": ["sfx", "music"]]),
                        "prompt": prop("string", "What it should sound like"),
                        "duration": prop(
                            "number", "Seconds (default: the model decides; music: the scene length when placing)"),
                        "loop": prop("boolean", "Sfx that loops seamlessly"),
                        "instrumental": prop("boolean", "Music without vocals (default true)"),
                        "model": prop("string", "fal audio model id (default: the catalog's; see image_status)"),
                        "name": prop("string", "File name base (default from the prompt)"),
                    ]), required: ["prompt"])
            ) { [unowned self] a in
                let s = try requireStore()
                let kind: AudioAI.Kind = a["kind"]?.string == "music" ? .music : .sfx
                var r = AudioAI.Request(kind: kind, prompt: try a.str("prompt"))
                var scene: Scene?
                if let sid = a["scene"]?.string { scene = try s.scene(sid) }
                r.duration =
                    a["duration"]?.double ?? (kind == .music ? scene.map { $0.duration - (a["at"]?.double ?? 0) } : nil)
                if let d = r.duration { r.duration = try SafeNumber.positive(d, "duration", max: 600) }
                r.loop = a["loop"]?.bool == true
                r.instrumental = a["instrumental"]?.bool ?? true
                if let m = a["model"]?.string?.lowercased(), !m.isEmpty {
                    guard FalProvider.isModelID(m) else { throw ToolError("model '\(m)' isn't a fal model id") }
                    r.model = m
                }
                let provider = try audioProvider()
                let req = r, name = a["name"]?.string
                let res = try blocking { try await AudioAI.generate(req, name: name, store: s, provider: provider) }
                var lines = [
                    "asset \(info(res.asset, store: s)) by \(AudioCatalog.entry(res.model)?.label ?? res.model) (fal.ai, paid)"
                ]
                if !res.failed.isEmpty { lines.append("tried first: " + res.failed.joined(separator: "; ")) }
                lines += try place(res.asset, a, store: s, defaultAs: kind == .music ? "audio" : "sound")
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "voice_generate",
                description:
                    "Speak a voiceover from text. engine local (default): the Mac's system voices — free, offline, good for drafts and timing (list:true shows the voices; Russian: Milena, Yuri; English: Samantha, Daniel…). engine fal: ElevenLabs multilingual (natural, expressive, 29 languages; costs money; voices such as Rachel, Aria, Sarah, Laura, Charlotte, Roger, George, Charlie, Liam, River). Write the text as it should be read (numbers as words where it matters, punctuation for pauses). With scene it becomes the scene's audio (as:\"sound\" for an extra line at 'at'). Then audio_analyze {scene, markers:\"phrases\"} gives you each sentence's time to animate to.",
                schema: schema(
                    MCPServer.with(place: [
                        "text": prop("string", "What to say"),
                        "engine": prop("string", "local (default) or fal", extra: ["enum": ["local", "fal"]]),
                        "voice": prop("string", "Voice name (default: picked for the text's language)"),
                        "speed": prop(
                            "number", "fal: 0.7–1.2 (default 1). local: words per minute 80–400 (default ~175)"),
                        "language": prop("string", "fal: ISO 639-1 code, e.g. ru, en"),
                        "list": prop("boolean", "Only list the local system voices"),
                        "name": prop("string", "File name base"),
                    ]))
            ) { [unowned self] a in
                if a["list"]?.bool == true {
                    let vs = Speech.voices()
                    let byLang = Dictionary(grouping: vs, by: { String($0.language.prefix(2)) })
                    return text(
                        byLang.keys.sorted().map { k in "\(k): " + byLang[k]!.map(\.name).joined(separator: ", ") }
                            .joined(separator: "\n"))
                }
                let s = try requireStore()
                let words = try a.str("text")
                if let sid = a["scene"]?.string { _ = try s.scene(sid) }
                var lines: [String]
                let asset: String
                if a["engine"]?.string == "fal" {
                    var r = AudioAI.Request(kind: .voice, prompt: words)
                    r.voice = a["voice"]?.string
                    r.speed = a["speed"]?.double
                    r.language = a["language"]?.string
                    let provider = try audioProvider()
                    let req = r, name = a["name"]?.string
                    let res = try blocking { try await AudioAI.generate(req, name: name, store: s, provider: provider) }
                    asset = res.asset
                    lines = [
                        "asset \(info(asset, store: s)) — voice by \(AudioCatalog.entry(res.model)?.label ?? res.model) (fal.ai, paid)"
                    ]
                } else {
                    let r = try Speech.write(
                        words, voice: a["voice"]?.string, rate: a["speed"]?.double, name: a["name"]?.string, store: s)
                    asset = r.asset
                    lines = [
                        "asset \(info(asset, store: s)) — system voice \(r.voice) (free; engine fal for a natural read)"
                    ]
                }
                lines += try place(asset, a, store: s, defaultAs: "audio")
                lines.append(
                    "To time pictures and sounds to its words: audio_transcribe (the time of every word) or audio_analyze {markers:\"phrases\"} (free: sentence starts)."
                )
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "audio_analyze",
                description:
                    "Measure a sound file or a scene's audio — your ears: loudness (LUFS, true peak), character (brightness, where the energy sits, attack, tail, strongest tone) and faults (clicks, clipping, silence at the start), then length, tempo (BPM) and beat times, onsets (every hit or new sound), phrases between pauses (voiceover sentences), the loudest moment and energy per second. Times are scene times when you pass scene (the clip's offset and trim applied), else file times. markers:\"beats\" | \"bars\" (every 4th beat) | \"onsets\" | \"phrases\" also writes them as scene markers (beat-1, bar-1, hit-1, line-1…) so layers can snap and expressions can use marker(\"beat-3\"). Cut animation on beats, land titles on bars or the loudest moment, and start each caption at its phrase.",
                schema: schema(
                    [
                        "src": prop("string", "A sound file in assets/ (or use scene)"),
                        "scene": prop("string", "Scene whose audio to analyse"),
                        "sound": prop("string", "With scene: a sound clip id instead of the scene audio"),
                        "markers": prop(
                            "string", "Write markers: beats, bars, onsets or phrases",
                            extra: ["enum": ["beats", "bars", "onsets", "phrases"]]),
                        "max_markers": prop("integer", "At most this many markers (default 48)"),
                        "image": prop(
                            "boolean",
                            "Also return a picture: spectrogram (frequency over time) with a loudness curve under it. Look at it to see where a sound's energy is and when."
                        ),
                    ])
            ) { [unowned self] a in
                let s = try requireStore()
                let (ref, scene) = try audioSource(a, store: s)
                let url = SceneAudio.url(ref, assets: s.assetsURL)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ToolError("'\(ref.src)' not found in assets/")
                }
                var r = try AudioAnalysis.analyze(url)
                // File time → scene time, keeping only what is heard inside the scene.
                if let sc = scene {
                    let shift = (ref.offset ?? 0) - (ref.trim ?? 0)
                    let p = SceneAudio.placement(ref, fileDuration: r.duration, sceneDuration: sc.duration)
                    let lo = p?.at ?? 0, hi = p.map { $0.at + $0.length } ?? 0
                    func map(_ t: Double) -> Double? {
                        let v = ((t + shift) * 1000).rounded() / 1000
                        return v >= lo - 1e-6 && v <= hi + 1e-6 ? v : nil
                    }
                    r.beats = r.beats.compactMap(map)
                    r.onsets = r.onsets.compactMap(map)
                    r.phrases = r.phrases.compactMap { ph in
                        let a = max(lo, ph.lowerBound + shift), b = min(hi, ph.upperBound + shift)
                        return b > a ? AudioAnalysis.round2(a)...AudioAnalysis.round2(b) : nil
                    }
                    r.loudest = ((r.loudest + shift) * 100).rounded() / 100
                }
                let stereo = try Stereo.read(url)
                var out =
                    AudioDescriptors.measure(stereo).summary + "\n"
                    + (scene != nil ? "times are scene times\n" : "times are file times\n") + r.summary
                var blocks: [JSONValue] = []
                if a["image"]?.bool == true {
                    let shift = scene != nil ? (ref.offset ?? 0) - (ref.trim ?? 0) : 0
                    let img = try AudioSheet.render(
                        stereo, start: shift, marks: (scene?.markers ?? []).map { ($0.name, $0.t) },
                        phrases: r.phrases)
                    if let jpg = ContactSheet.jpeg(img) {
                        blocks.append([
                            "type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg",
                        ])
                    }
                }
                if let kind = a["markers"]?.string, let sc = scene {
                    let maxN = try SafeNumber.int(a["max_markers"]?.double ?? 48, "max_markers", in: 1...400)
                    let (prefix, times): (String, [Double]) =
                        switch kind {
                        case "beats": ("beat", r.beats)
                        case "bars": ("bar", stride(from: 0, to: r.beats.count, by: 4).map { r.beats[$0] })
                        case "onsets": ("hit", r.onsets)
                        default: ("line", r.phrases.map(\.lowerBound))
                        }
                    guard !times.isEmpty else {
                        return blocks + text(out + "\nno \(kind) found — no markers written")
                    }
                    let picked = Array(times.prefix(maxN))
                    // Replace this kind's earlier markers so a re-run doesn't pile up stale ones.
                    var ops: [JSONValue] = (sc.markers ?? []).filter { m in
                        m.name.hasPrefix(prefix + "-") && Int(m.name.dropFirst(prefix.count + 1)) != nil
                    }.map { ["op": "marker", "name": .string($0.name), "remove": true] }
                    ops += picked.enumerated().map { k, t in
                        ["op": "marker", "name": .string("\(prefix)-\(k + 1)"), "t": .number(t)]
                    }
                    let applied = try SceneOps.apply(ops, to: sc)
                    let saved = try saveValidated(
                        applied.scene, store: s, expectedRev: sc.rev, summary: "\(kind) markers")
                    out +=
                        "\nwrote \(picked.count) markers \(prefix)-1…\(prefix)-\(picked.count)\(times.count > picked.count ? " (of \(times.count))" : "") in \(sc.id) (rev \(saved.rev)); use marker(\"\(prefix)-1\") in expressions or snap keys to them"
                } else if a["markers"] != nil {
                    out += "\n(markers need scene)"
                }
                return blocks + text(out)
            },

            Tool(
                name: "audio_transcribe",
                description:
                    "The words of a voiceover with the time each one is spoken (speech-to-text: ElevenLabs Scribe on fal.ai, the user's key, a few cents a minute; a file is transcribed once and then read from the project). Use it whenever something must land on a word or a line — a sound on \"…one step away\", a title when its word is said, captions — instead of guessing from pauses. With scene the times are scene times (the clip's offset and trim applied). find: a word or phrase → just its times. mark: words or phrases to write as scene markers (say-<word>) so keys and sounds can snap to them.",
                schema: schema(
                    [
                        "src": prop("string", "A sound file in assets/ (or use scene)"),
                        "scene": prop("string", "Scene whose audio to transcribe"),
                        "sound": prop("string", "With scene: a sound clip id instead of the scene audio"),
                        "language": prop(
                            "string", "Language code when you know it (\"ru\", \"en\"); default: detected"),
                        "find": prop("string", "Only report when this word or phrase is said"),
                        "mark": prop(
                            "array", "Words or phrases to write as markers at the moment they start",
                            extra: ["items": ["type": "string"]]),
                    ])
            ) { [unowned self] a in
                let s = try requireStore()
                let (ref, scene) = try audioSource(a, store: s)
                // The original file: effects don't change the words, and stretching is undone below.
                let file = AssetPath.url(ref.src, assets: s.assetsURL)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw ToolError("'\(ref.src)' not found in assets/")
                }
                let language = a["language"]?.string
                let (t, fresh): (Transcript, Bool)
                if let c = Transcript.cached(file, store: s) {
                    (t, fresh) = (c, false)
                } else {
                    let provider = try transcriptProvider()
                    (t, fresh) = try blocking {
                        try await Transcript.of(file, language: language, store: s, provider: provider)
                    }
                }
                // File time → scene time (a stretched clip plays its words 1/rate apart).
                let rate = ref.rate ?? 1
                let shift = scene != nil ? (ref.offset ?? 0) - (ref.trim ?? 0) : 0
                func at(_ x: Double) -> Double { ((x / rate + shift) * 100).rounded() / 100 }
                var out = [
                    "\(ref.src): \(t.words.count) words" + (t.language.map { ", language \($0)" } ?? "")
                        + (fresh ? " (transcribed now, paid)" : " (from the project's saved transcript)")
                        + (scene != nil ? "; times are scene times" : "; times are file times")
                ]
                if let q = a["find"]?.string, !q.isEmpty {
                    let hits = t.find(q)
                    out.append(
                        hits.isEmpty
                            ? "“\(q)” is not said. The text: \(t.text)"
                            : "“\(q)”: "
                                + hits.map {
                                    "\(Format.number(at($0.lowerBound)))–\(Format.number(at($0.upperBound)))s"
                                }.joined(separator: ", "))
                } else {
                    // In a scene, only what is said while the scene runs (a long voiceover covers many scenes).
                    let end = scene?.duration ?? .infinity
                    var skipped = 0
                    for line in t.lines {
                        guard let f = line.first, let l = line.last else { continue }
                        if scene != nil, at(l.end) < 0 || at(f.start) > end { skipped += line.count; continue }
                        out.append(
                            "\(Format.number(at(f.start)))–\(Format.number(at(l.end)))s  "
                                + line.map(\.text).joined(separator: " "))
                        out.append(
                            "    " + line.map { "\($0.text)@\(Format.number(at($0.start)))" }.joined(separator: " "))
                    }
                    if skipped > 0 {
                        out.append("(\(skipped) more words are said outside this scene; use src for the whole file)")
                    }
                }
                if let marks = a["mark"]?.array?.compactMap(\.string), !marks.isEmpty {
                    guard let sc = scene else { return text(out.joined(separator: "\n") + "\n(markers need scene)") }
                    var ops: [JSONValue] = []
                    var names: [String] = []
                    for m in marks {
                        guard let hit = t.find(m).first else { out.append("not marked: “\(m)” is not said"); continue }
                        let name = "say-" + AudioFiles.slug(m)
                        ops.append(["op": "marker", "name": .string(name), "t": .number(at(hit.lowerBound))])
                        names.append("\(name)@\(Format.number(at(hit.lowerBound)))")
                    }
                    if !ops.isEmpty {
                        let applied = try SceneOps.apply(ops, to: sc)
                        let saved = try saveValidated(
                            applied.scene, store: s, expectedRev: sc.rev, summary: "word markers")
                        out.append("wrote markers \(names.joined(separator: ", ")) in \(sc.id) (rev \(saved.rev))")
                    }
                }
                return text(out.joined(separator: "\n"))
            },

            Tool(
                name: "sound_notes",
                description:
                    "The project's sound notes: what the user wants it to sound like, kept across chats (.arclight/sound.md). No arguments: read them — do it before any sound job. add: one line after each reaction of the user to a sound — what they liked, rejected and why, levels they settled on, the palette (\"food moment: wants a very low velvety bloop; rejected chime (harsh) and pop (too bright)\"). write: replace all the notes with a tidied version when they get long or contradict each other.",
                schema: schema(
                    [
                        "add": prop("string", "One line to add"),
                        "write": prop("string", "The whole notes, replacing what is there (max 4000 characters)"),
                    ])
            ) { [unowned self] a in
                let s = try requireStore()
                if let w = a["write"]?.string {
                    try SoundNotes.write(w, project: s.url)
                    return text("sound notes replaced:\n" + (SoundNotes.read(s.url) ?? "(empty)"))
                }
                if let line = a["add"]?.string, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text("sound notes:\n" + (try SoundNotes.add(line, project: s.url)))
                }
                return text(
                    SoundNotes.read(s.url).map { "sound notes:\n" + $0 }
                        ?? "no sound notes yet — add one after the user reacts to a sound (sound_notes {add:\"…\"})")
            },

            Tool(
                name: "mix_check",
                description:
                    "Check how the scene's sound sits together — do this after every sound edit, before you answer, the way you render frames after a visual edit. You cannot hear; this measures. Renders the whole mix (every clip placed, trimmed, faded) and returns: overall loudness (LUFS) and true peak; for each clip when it sounds, how loud it is, how loud everything else is at that moment and how it compares with the scene audio (voice or music); and the problems found — distortion, a clip louder than the voice, a clip buried or silent, cuts that click, files missing. Plus a picture: spectrogram, loudness curve with the speech phrases shaded, the clips as lanes, markers as lines. Fix the problems and run it again. from/to limit it to a stretch of the scene.",
                schema: schema(
                    [
                        "scene": prop("string", "Scene id"),
                        "from": prop("number", "Start of the stretch to check (s, default 0)"),
                        "to": prop("number", "End of the stretch (s, default the scene end)"),
                        "image": prop("boolean", "Return the picture too (default true)"),
                    ], required: ["scene"]),
                readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let scene = try s.scene(try a.str("scene"))
                let from = max(0, a["from"]?.double ?? 0)
                let to = min(scene.duration, a["to"]?.double ?? scene.duration)
                guard to > from else { throw ToolError("'to' must be after 'from'") }
                let rendered = SceneMix.render(scene, assets: s.assetsURL)
                guard !rendered.stems.isEmpty else {
                    return text(
                        "\(scene.id) has no sound"
                            + (rendered.missing.isEmpty
                                ? "" : " (files not found: \(rendered.missing.joined(separator: ", ")))"))
                }
                let whole = from <= 0 && to >= scene.duration
                let report = MixReport.make(scene, rendered: rendered, from: whole ? nil : from, to: whole ? nil : to)
                var blocks: [JSONValue] = []
                if a["image"]?.bool != false {
                    let i0 = Int(from * Stereo.rate), i1 = min(rendered.mix.count, Int(to * Stereo.rate))
                    let part = Stereo(l: Array(rendered.mix.l[i0..<i1]), r: Array(rendered.mix.r[i0..<i1]))
                    var phrases: [ClosedRange<Double>] = []
                    if let ref = rendered.stems.first(where: \.isReference) {
                        let t0 = Double(ref.start) / Stereo.rate
                        phrases = AudioAnalysis.analyze(samples: ref.audio.mono, sampleRate: Stereo.rate).phrases.map {
                            ($0.lowerBound + t0)...($0.upperBound + t0)
                        }
                    }
                    let lanes = rendered.stems.filter {
                        Double($0.range.upperBound) / Stereo.rate >= from && Double($0.start) / Stereo.rate <= to
                    }
                    .map {
                        AudioSheet.Lane(
                            label: $0.id, from: Double($0.start) / Stereo.rate,
                            to: Double($0.range.upperBound) / Stereo.rate, highlight: $0.isReference)
                    }
                    let img = try AudioSheet.render(
                        part, start: from, lanes: lanes, marks: (scene.markers ?? []).map { ($0.name, $0.t) },
                        phrases: phrases)
                    if let jpg = ContactSheet.jpeg(img) {
                        blocks.append([
                            "type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg",
                        ])
                    }
                }
                return blocks
                    + text("\(scene.id) rev \(scene.rev), \(Format.number(from))–\(Format.number(to))s\n" + report.text)
            },
        ]
    }
}
