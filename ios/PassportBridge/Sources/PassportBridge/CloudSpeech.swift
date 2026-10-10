import Foundation

public enum CloudSpeechRequestFailure: Error { case configuration, http(Int) }

public func cloudSpeechFailureDescription(_ error: Error) -> String {
    switch error {
    case CloudSpeechRequestFailure.configuration:
        return "请检查密钥、模型资源 ID 和音色 ID"
    case let CloudSpeechRequestFailure.http(status):
        return "HTTP \(status)，请检查服务权限、密钥与额度"
    case let SpeechFailure.cloud(code):
        return "服务错误码 \(code)，请检查模型、音色权限与额度"
    case is URLError:
        return "网络请求失败，请检查网络后重试"
    case SpeechFailure.format, SpeechFailure.incomplete:
        return "云端音频响应不完整或格式异常，请重试"
    case SpeechFailure.limit:
        return "云端音频超过大小限制"
    default:
        return "合成或播放未完成，请重试"
    }
}

/// Downloads one bounded sentence before its PCM enters paced BLE playback.
/// Cloud response gaps must affect startup, not split a sentence already heard.
@MainActor
public func consumeCloudSpeechSentence(
    next: @MainActor () async throws -> UInt8?,
    consume: @MainActor ([Int16]) async throws -> Void
) async throws {
    var parser = VolcSpeechParser(), chunk = Data(), audio = Data()
    func accept(_ data: Data) throws {
        for part in try parser.feed(data) {
            guard part.count <= 2_000_000 - audio.count else { throw SpeechFailure.limit }
            audio += part
        }
    }
    while let byte = try await next() {
        try Task.checkCancellation(); chunk.append(byte)
        if chunk.count >= 4096 || byte == 10 {
            try accept(chunk); chunk.removeAll(keepingCapacity: true)
        }
    }
    if !chunk.isEmpty { try accept(chunk) }
    try parser.finish()
    guard !audio.isEmpty, audio.count % 2 == 0 else { throw SpeechFailure.format }
    let pcm: [Int16] = audio.withUnsafeBytes { bytes in
        var samples: [Int16] = []
        samples.reserveCapacity(bytes.count / 2)
        for offset in stride(from: 0, to: bytes.count, by: 2) {
            let value = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            samples.append(Int16(bitPattern: value))
        }
        return samples
    }
    audio.removeAll(keepingCapacity: false)
    try Task.checkCancellation()
    try await consume(pcm)
}
