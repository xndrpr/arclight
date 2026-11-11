import Foundation
import Testing

@testable import ArclightCore

/// Pins `Doctor.check`: which problems it reports, in which order, with which kind, severity and message.
@Suite(.serialized) struct DoctorCharacterizationTests {
    func store(
        _ build: (inout ArclightCore.Scene) -> Void, theme: [String: JSONValue]? = nil
    ) throws -> (ProjectStore, URL) {
        let p = try TempProject("doctor")
        let st = p.store
        if let theme { var p = st.project; p.theme = theme; try st.update(project: p) }
        var s = ArclightCore.Scene(id: "s", duration: 2)
        build(&s)
        try st.save(scene: s)
        return (st, p.url)
    }

    func lines(_ st: ProjectStore) -> [String] {
        Doctor.check(st).map { "\($0.severity.rawValue) \($0.kind) \($0.scene)/\($0.node ?? "-"): \($0.message)" }
    }

    @Test func cleanProjectHasNoProblems() throws {
        let (st, dir) = try store { s in
            s.nodes = [
                Node(
                    id: "t", type: "text",
                    props: ["text": .value("Hi"), "color": .value("$fg"), "font": .value("$display")]),
                Node(id: "sym", type: "symbol"), Node(id: "sh", type: "shape"),
            ]
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Doctor.check(st).isEmpty)
    }

    @Test func reportsEachKindWithItsMessage() throws {
        let (st, dir) = try store { s in
            s.background = .value("$paper")
            s.fog = .keys([Keyframe(t: 0, v: ["color": "$glow", "near": 100, "far": 900])])
            s.audio = AudioRef(src: "vo.wav")
            s.nodes = [
                Node(
                    id: "t", type: "text",
                    props: ["text": .value("Hi"), "font": .value("NoSuchFont-Bold"), "color": .value("$brand")]),
                Node(id: "img", type: "image", props: ["src": .value("missing.png")]),
                Node(id: "abs", type: "image", props: ["src": .value("/no/such/file.png")]),
                Node(id: "sym", type: "symbol", props: ["symbol": .value("brand/logo")]),
                Node(
                    id: "rep", type: "repeater",
                    props: ["items": .value([["src": "a.png"], ["symbol": "basic/person"], ["symbol": "x/y"]])]),
            ]
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(
            lines(st) == [
                "warning token s/-: background uses $paper, which is not in the theme",
                "warning token s/-: fog uses $glow, which is not in the theme",
                "warning token s/t: uses $brand, which is not in the theme",
                "warning font s/t: font 'NoSuchFont-Bold' is not installed — falls back to Helvetica (add it to the project's fonts/ folder)",
                "error asset s/img: image 'missing.png' not found in assets/",
                "error asset s/abs: image '/no/such/file.png' not found in assets/",
                "error symbol s/sym: symbol 'brand/logo' not found (see symbol_list) — the layer draws nothing",
                "error asset s/rep: items[0] image 'a.png' not found",
                "error symbol s/rep: items[2] symbol 'x/y' not found (see symbol_list)",
                "error asset s/-: audio 'vo.wav' not found in assets/",
            ])
    }

    @Test func validationIssuesAreClassifiedByMessage() throws {
        let (st, dir) = try store { s in
            s.nodes = [Node(id: "e", type: "shape", props: ["x": .expr("t +* 2")]), Node(id: "u", type: "blob")]
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let ps = Doctor.check(st)
        #expect(ps.allSatisfy { $0.severity == .error })
        #expect(ps.first { $0.node == "e" }?.kind == "expression")
        #expect(ps.first { $0.node == "u" }?.kind == "schema")
    }

    @Test func presentFilesAndThemeFontTokensPass() throws {
        let (st, dir) = try store(
            { s in
                s.nodes = [
                    Node(id: "img", type: "image", props: ["src": .value("here.png")]),
                    Node(id: "t", type: "text", props: ["text": .value("Hi")]),
                ]  // font defaults to $display
            }, theme: ["display": "NoSuchFont-Bold", "fg": "#fff", "bg": "#000"])
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: st.assetsURL, withIntermediateDirectories: true)
        try Data([0]).write(to: st.assetsURL.appendingPathComponent("here.png"))
        // The image exists (contents aren't checked); the default font resolves through $display and is reported.
        #expect(
            lines(st) == [
                "warning font s/t: font 'NoSuchFont-Bold' is not installed — falls back to Helvetica (add it to the project's fonts/ folder)"
            ])
    }
}
