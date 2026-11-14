import Foundation
import Synchronization

/// Answers URLSession requests in tests without a network. Handlers are
/// registered per host, so tests running in parallel each use their own
/// made-up host (e.g. `https://sign-in-test.invalid`) and never see each
/// other's requests.
/// What a stub answers with.
struct StubResponse {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(_ status: Int, _ body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> StubResponse

    private static let handlers = Mutex<[String: Handler]>([:])

    /// Routes every request to `host` to `handler`, which gets the request
    /// and its body (read from the body stream, which is how URLSession
    /// hands bodies to protocols).
    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        handlers.withLock { $0[host] = nil }
    }

    /// A session that only reaches these stubs.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host(),
            let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let answer = try handler(request, Self.body(of: request))
            var headers = ["Content-Type": "application/json"]
            headers.merge(answer.headers) { _, new in new }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 16 * 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 16 * 1024)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The fields of an `application/x-www-form-urlencoded` body.
func formFields(_ data: Data?) -> [String: String] {
    guard let data else { return [:] }
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: data, as: UTF8.self)
    var fields: [String: String] = [:]
    for item in components.queryItems ?? [] {
        fields[item.name] = item.value ?? ""
    }
    return fields
}
