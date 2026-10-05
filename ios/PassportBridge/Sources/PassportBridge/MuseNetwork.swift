import Foundation

/// Why a network call failed, without any text that could carry a URL, a
/// header or a credential.
public enum MuseNetworkError: Error, Equatable, Sendable {
    case dns, timeout, tls, connect, io
    /// The WebSocket upgrade was refused with this HTTP status.
    case webSocketHTTP(Int)
}

public protocol MuseSocket: Sendable {
    func send(_ data: Data) async throws
    /// The next binary message; throws once the connection has ended.
    func receive() async throws -> Data
    func close()
}

/// The app's system networking, behind a seam so the bridge is testable.
public protocol MuseNetwork: Sendable {
    func http(_ method: String, _ url: URL, headers: [String: String], body: Data?) async throws -> (status: Int, body: Data)
    func openWebSocket(_ url: URL, headers: [String: String]) async throws -> any MuseSocket
}

/// A failure of the Muse connection, with text that is safe to display.
enum BridgeFailure: Error, Equatable {
    /// The account binding or authorization is gone; retrying cannot help.
    case permanent(String)
    case transient(String)
}

struct TimedOut: Error {}

/// A credential-free description of why a connection stage failed.
func failureReason(_ error: Error) -> String {
    switch error {
    case let BridgeFailure.permanent(text), let BridgeFailure.transient(text): return text
    case is TimedOut: return "等待 Muse 响应超时"
    case MuseNetworkError.dns: return "域名解析失败，请检查 Muse Passport 的网络及 VPN 分应用规则"
    case MuseNetworkError.timeout: return "网络请求超时，请检查 Muse Passport 的网络及 VPN 分应用规则"
    case MuseNetworkError.tls: return "TLS 安全连接失败，请检查手机时间及 VPN 设置"
    case MuseNetworkError.connect: return "无法建立网络连接，请检查 Muse Passport 的网络及 VPN 分应用规则"
    case MuseNetworkError.io: return "网络传输中断，请检查 Muse Passport 的网络及 VPN 分应用规则"
    case let MuseNetworkError.webSocketHTTP(status): return "Muse WebSocket HTTP \(status)"
    default: return "连接协议异常 (\(type(of: error)))"
    }
}
