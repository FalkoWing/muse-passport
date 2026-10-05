import Foundation
import PassportBridge

/// The system's own networking: default routing, VPN and TLS trust, no proxy
/// settings of our own, and no redirects.
struct SystemNetwork: MuseNetwork {
    private static let limit = 1024 * 1024

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Never forward an error's own text: it can contain URLs or headers.
    static func classify(_ error: Error) -> Error {
        guard let error = error as? URLError else { return error is CancellationError ? error : MuseNetworkError.io }
        switch error.code {
        case .cancelled: return CancellationError()
        case .cannotFindHost, .dnsLookupFailed: return MuseNetworkError.dns
        case .timedOut: return MuseNetworkError.timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return MuseNetworkError.tls
        case .cannotConnectToHost, .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return MuseNetworkError.connect
        default: return MuseNetworkError.io
        }
    }

    private func request(_ url: URL, _ headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        return request
    }

    func http(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data) {
        var request = request(url, headers)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard data.count <= Self.limit, let response = response as? HTTPURLResponse else { throw MuseNetworkError.io }
            return (response.statusCode, data)
        } catch {
            throw Self.classify(error)
        }
    }

    func openWebSocket(_ url: URL, headers: [String: String]) async throws -> any MuseSocket {
        let task = session.webSocketTask(with: request(url, headers))
        task.maximumMessageSize = Self.limit
        task.resume()
        return SystemSocket(task: task)
    }
}

final class SystemSocket: MuseSocket {
    private let task: URLSessionWebSocketTask
    private let keepAlive: Task<Void, Never>

    init(task: URLSessionWebSocketTask) {
        self.task = task
        // Without traffic a dead connection would go unnoticed while awake.
        keepAlive = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { return }
                task.sendPing { error in
                    if error != nil { task.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
    }

    /// A refused upgrade is reported by its HTTP status, as on Android.
    private func failure(_ error: Error) -> Error {
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            return MuseNetworkError.webSocketHTTP(status)
        }
        return SystemNetwork.classify(error)
    }

    func send(_ data: Data) async throws {
        do { try await task.send(.data(data)) } catch { throw failure(error) }
    }

    func receive() async throws -> Data {
        do {
            guard case let .data(data) = try await task.receive() else { throw MuseNetworkError.io }
            return data
        } catch {
            throw failure(error)
        }
    }

    func close() {
        keepAlive.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }
}
