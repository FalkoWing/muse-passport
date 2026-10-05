import Foundation

public enum AudioUploadError: Error {
    case alreadyEnded, shortHeader, invalidBlock
}

/// Passport IMA ADPCM blocks in, a streaming base64 WAV request body out.
///
/// State is explicit on every block and a sequence gap rejects the turn.
/// Only the Bluetooth hop is compressed; Muse receives 16 kHz mono PCM.
public struct AudioUpload: Sendable {
    /// The JSON that precedes the base64 audio in the request body.
    public static let head = Data(#"{"message":"","output_modality":"text","items":[{"type":"file","mime_type":"audio/wav","filename":"voice_note.wav","data_base64":""#.utf8)
    static let tail = Data(#""}]}"#.utf8)

    private static let steps: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
        4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
        22385, 24623, 27086, 29794, 32767,
    ]
    private static let indexDelta = [-1, -1, -1, -1, 2, 4, 6, 8]

    /// A streaming WAV header: the two length fields stay at 0xFFFFFFFF.
    private static let wav: [UInt8] = {
        func le(_ value: UInt32, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(value >> (8 * UInt32($0)) & 255) } }
        return Array("RIFF".utf8) + le(0xFFFF_FFFF, 4) + Array("WAVEfmt ".utf8) + le(16, 4) + le(1, 2) + le(1, 2)
            + le(16000, 4) + le(32000, 4) + le(2, 2) + le(16, 2) + Array("data".utf8) + le(0xFFFF_FFFF, 4)
    }()

    private var pending = AudioUpload.wav
    private var sequence: UInt32 = 0
    private var ended = false
    public private(set) var samples = 0

    public init() {}

    /// Decodes whole blocks and returns the next piece of base64 text.
    public mutating func feed(_ data: Data, end: Bool = false) throws -> Data {
        guard !ended else { throw AudioUploadError.alreadyEnded }
        let bytes = [UInt8](data)
        var position = 0
        var pcm: [UInt8] = []
        while position < bytes.count {
            guard bytes.count - position >= 9 else { throw AudioUploadError.shortHeader }
            var predictor = Int(Int16(bitPattern: UInt16(bytes[position]) | UInt16(bytes[position + 1]) << 8))
            var index = Int(bytes[position + 2])
            let count = Int(bytes[position + 3]) | Int(bytes[position + 4]) << 8
            let blockSequence = (5...8).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[position + $1]) }
            position += 9
            guard index <= 88, count != 0, count <= 320, count % 2 == 0, blockSequence == sequence,
                  bytes.count - position >= count / 2 else { throw AudioUploadError.invalidBlock }
            sequence += 1
            samples += count
            for packed in bytes[position..<position + count / 2] {
                for code in [Int(packed & 15), Int(packed >> 4)] {
                    let step = Self.steps[index]
                    let difference = (step >> 3) + (code & 4 != 0 ? step : 0) + (code & 2 != 0 ? step >> 1 : 0)
                        + (code & 1 != 0 ? step >> 2 : 0)
                    predictor = max(-32768, min(32767, predictor + (code & 8 != 0 ? -difference : difference)))
                    index = max(0, min(88, index + Self.indexDelta[code & 7]))
                    let sample = UInt16(bitPattern: Int16(predictor))
                    pcm += [UInt8(sample & 255), UInt8(sample >> 8)]
                }
            }
            position += count / 2
        }
        pending += pcm
        // Base64 only splits cleanly on three-byte boundaries.
        let size = end ? pending.count : pending.count / 3 * 3
        var result = Data(pending[..<size]).base64EncodedData()
        pending.removeFirst(size)
        if end {
            ended = true
            result += Self.tail
        }
        return result
    }
}
