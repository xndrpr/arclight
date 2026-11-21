import Foundation

/// GET requests to the free asset libraries (Openverse, Poly Haven): no key, a 60 s timeout, and the library's own
/// message for a failed status code.
enum LibraryHTTP {
    static func get(_ url: URL, session: URLSession, failure: (Int) -> String) async throws -> Data {
        var r = URLRequest(url: url)
        r.setValue("Arclight", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 60
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(code) else { throw ImageAIError.failed(failure(code)) }
        return data
    }
}
