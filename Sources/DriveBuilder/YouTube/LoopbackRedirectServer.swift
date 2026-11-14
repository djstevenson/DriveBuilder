import Foundation
import Network
import Synchronization

/// The redirect target for a desktop sign-in: listens on a free port of
/// 127.0.0.1 for the one request Google's sign-in page sends the browser
/// back with, hands over its query, and shows the browser a note that it
/// can be closed.
///
/// Google's desktop-app clients accept any loopback port without
/// registering it, so this works without a custom URL scheme, which a bare
/// SPM executable couldn't declare anyway.
final class LoopbackRedirectServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackRedirectServer")
    /// The one waiting `callback()`, resumed by the first request in.
    private let waiter = Mutex<CheckedContinuation<[String: String], any Error>?>(nil)
    private let connections = Mutex<[NWConnection]>([])

    /// Starts listening. Throws if no loopback port could be bound.
    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let shouldResume = resumed.withLock { done -> Bool in
                    if done { return false }
                    switch state {
                    case .ready, .failed, .cancelled: done = true; return true
                    default: return false
                    }
                }
                guard shouldResume else { return }
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The bound port, for the redirect URI.
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    /// The URI Google must send the browser back to.
    var redirectURI: String { "http://127.0.0.1:\(port)" }

    /// Waits for the browser's redirect and returns its query parameters
    /// (`code` and `state`, or `error`), decoded.
    func callback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            waiter.withLock { $0 = continuation }
        }
    }

    /// Stops listening and drops any open connection.
    func stop() {
        listener.cancel()
        connections.withLock { connections in
            for connection in connections {
                connection.cancel()
            }
            connections = []
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.withLock { $0.append(connection) }
        connection.start(queue: queue)
        receiveRequest(connection, buffered: Data())
    }

    /// Reads until the request head is complete, then answers it. Browsers
    /// may open extra connections (favicon, speculative) that send nothing
    /// or something other than the redirect; those just get a 404.
    private func receiveRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffered = buffered
            if let data { buffered.append(data) }
            if let headEnd = buffered.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffered[..<headEnd.lowerBound], as: UTF8.self)
                respond(to: head, on: connection)
            } else if isComplete || error != nil || buffered.count > 64 * 1024 {
                connection.cancel()
            } else {
                receiveRequest(connection, buffered: buffered)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
            let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
            components.path == "/", let items = components.queryItems, !items.isEmpty
        else {
            send(status: "404 Not Found", body: "Not found", on: connection)
            return
        }
        var query: [String: String] = [:]
        for item in items {
            query[item.name] = item.value ?? ""
        }
        let body =
            query["error"] == nil
            ? "<!doctype html><meta charset=utf-8><title>DriveBuilder Studio</title>"
                + "<body style=\"font-family: -apple-system, sans-serif; padding: 2em\">"
                + "<h1>Signed in</h1><p>You can close this window and return to DriveBuilder Studio.</p>"
            : "<!doctype html><meta charset=utf-8><title>DriveBuilder Studio</title>"
                + "<body style=\"font-family: -apple-system, sans-serif; padding: 2em\">"
                + "<h1>Sign-in cancelled</h1><p>You can close this window.</p>"
        send(status: "200 OK", body: body, on: connection)
        let continuation = waiter.withLock { waiter -> CheckedContinuation<[String: String], any Error>? in
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: query)
    }

    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let head =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data(head.utf8) + bodyData,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}
