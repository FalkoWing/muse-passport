import Foundation

/// Message types of the phone bridge. Must match `phone_bridge.c` and the
/// Android `BridgeProtocol`.
public enum BridgeMessageType {
    public static let hello: UInt8 = 1, credentials: UInt8 = 2, ready: UInt8 = 3
    public static let open: UInt8 = 4, data: UInt8 = 5, cancel: UInt8 = 6
    public static let response: UInt8 = 7, ack: UInt8 = 8, tokens: UInt8 = 9
    public static let error: UInt8 = 10, text: UInt8 = 11, sdkSettings: UInt8 = 12
    public static let speechRequest: UInt8 = 13, speechData: UInt8 = 14, speechStatus: UInt8 = 15
}

public struct BridgeMessage: Equatable, Sendable {
    public var type: UInt8
    public var id: UInt16
    public var sequence: UInt16
    public var body: Data

    public init(type: UInt8, id: UInt16, sequence: UInt16, body: Data) {
        self.type = type
        self.id = id
        self.sequence = sequence
        self.body = body
    }
}

public enum BridgeFrameError: Error {
    case header, overlap, order, size
}

/// Version 1 framing: type, flags, request ID, message sequence, byte offset
/// (u8 u8 u16 u16 u16, little endian), then the payload. Flag bit 0 marks the
/// first packet of a message and bit 1 the last.
public struct BridgeFrames: Sendable {
    public static let maxMessage = 8192
    public static let header = 8

    private var partial: BridgeMessage?

    public init() {}

    public mutating func reset() { partial = nil }

    /// Returns a message once its last packet arrives.
    public mutating func feed(_ packet: Data) throws -> BridgeMessage? {
        let bytes = [UInt8](packet)
        guard bytes.count >= Self.header, bytes[1] & ~3 == 0 else { throw BridgeFrameError.header }
        let type = bytes[0], flags = bytes[1]
        let id = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        let sequence = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        let offset = Int(bytes[6]) | Int(bytes[7]) << 8
        if flags & 1 != 0 {
            guard partial == nil, offset == 0 else {
                partial = nil
                throw BridgeFrameError.overlap
            }
            partial = BridgeMessage(type: type, id: id, sequence: sequence, body: Data())
        }
        guard var message = partial, message.type == type, message.id == id, message.sequence == sequence,
              message.body.count == offset, offset + bytes.count - Self.header <= Self.maxMessage else {
            partial = nil
            throw BridgeFrameError.order
        }
        message.body.append(contentsOf: bytes[Self.header...])
        partial = flags & 2 == 0 ? message : nil
        return flags & 2 == 0 ? nil : message
    }

    /// Splits one message into packets no larger than the link allows.
    public static func packets(type: UInt8, id: UInt16, sequence: UInt16, body: Data, mtu: Int) throws -> [Data] {
        guard body.count <= maxMessage, mtu >= 23 else { throw BridgeFrameError.size }
        let bytes = [UInt8](body)
        let size = min(mtu - 3, 244) - header
        var result: [Data] = []
        var offset = 0
        repeat {
            let count = min(size, bytes.count - offset)
            var packet: [UInt8] = [type, (offset == 0 ? 1 : 0) | (offset + count == bytes.count ? 2 : 0)]
            for value in [id, sequence, UInt16(offset)] { packet += [UInt8(value & 255), UInt8(value >> 8)] }
            packet += bytes[offset..<offset + count]
            result.append(Data(packet))
            offset += count
        } while offset < bytes.count
        return result
    }
}
