import CoreGraphics
import Foundation

/// AI 3D models: a picture of one object (generated from a prompt, or an asset) → background removed on-device →
/// image-to-3D (fal.ai) → a .glb in assets/. The picture is kept next to it (`<name>-ref.png`) so the model can be
/// remade or compared.
public enum ModelAI {
    public struct Result: Sendable {
        /// The model file in assets/.
        public var asset: String
        /// The picture it was made from, in assets/.
        public var reference: String
        public var triangles: Int
    }

    /// What's added to a prompt so the picture suits image-to-3D: one whole object, nothing around it.
    static let objectStyle =
        "a single object, the whole of it in view, centred, on a plain light grey studio background, soft even light, no shadows, no text"

    public static func generate(
        prompt: String?, source: String?, name: String?, store: ProjectStore, provider: ImageProvider
    ) async throws -> Result {
        let base = ImageAI.slug(name ?? prompt ?? source.map(ImageAI.stem) ?? "model")
        let picture: CGImage
        let reference: String
        if let source {
            picture = try ImageData.load(AssetPath.url(source, assets: store.assetsURL))
            reference = source
        } else if let prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            picture = try await provider.generate(
                prompt: prompt + ", " + objectStyle, width: 1024, height: 1024, seed: nil)
            reference = try ImageAI.write(picture, base: base + "-ref", store: store)
            ImageAI.log(store, op: "generate", model: provider.name, prompt: prompt, source: nil, asset: reference)
        } else {
            throw ImageAIError.failed("model_generate needs a prompt or a source image")
        }
        // A clean cut-out gives image-to-3D a clear silhouette; on-device, and skipped if it finds nothing.
        let cutout = (try? LocalVisionProvider().removeBackground(image: picture)) ?? picture
        let glb = try await provider.model3D(image: cutout)
        let mesh: Mesh
        do { mesh = try GLB.parse(glb) } catch {
            throw ImageAIError.failed("the 3D model came back unreadable (\(error))")
        }
        let asset = try writeModel(glb, base: base, store: store)
        ImageAI.log(store, op: "model", model: provider.name, prompt: prompt, source: reference, asset: asset)
        return Result(asset: asset, reference: reference, triangles: mesh.triangleCount)
    }

    /// Writes .glb bytes into assets/ under a free name (`base.glb`, `base-2.glb`, …).
    static func writeModel(_ data: Data, base: String, store: ProjectStore) throws -> String {
        try FileManager.default.createDirectory(at: store.assetsURL, withIntermediateDirectories: true)
        var name = "\(base).glb", k = 2
        while FileManager.default.fileExists(atPath: store.assetsURL.appendingPathComponent(name).path) {
            name = "\(base)-\(k).glb"; k += 1
        }
        try data.write(to: store.assetsURL.appendingPathComponent(name), options: .atomic)
        return name
    }

    /// A small scene that turns the model once (front, right, back, left at t = 0…3), for a contact sheet.
    public static func turntable(_ asset: String, project: Project) -> Scene {
        let (w, h) = project.size(for: Scene(id: "turntable", duration: 4))
        var s = Scene(id: "turntable", duration: 4)
        s.background = .value("#2a2a2e")
        s.nodes = [
            Node(
                id: "model", type: "model",
                props: [
                    "src": .value(.string(asset)), "x": .value(.number(Double(w) / 2)),
                    "y": .value(.number(Double(h) / 2)), "size": .value(.number(Double(min(w, h)) * 0.7)),
                    "material": .value("clay"), "color": .value("#d8d4cc"),
                    "rotationY": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 4, v: 360)]),
                ])
        ]
        return s
    }
}
