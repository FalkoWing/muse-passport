import Foundation
import Testing

/// Loads a vector file produced by `ios/tools/generate_vectors.py`.
func fixture(_ name: String) throws -> Any {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONSerialization.jsonObject(with: Data(contentsOf: url))
}

/// Key-sorted JSON text, so values compare regardless of key order while
/// booleans and numbers stay distinct.
func canonical(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]),
           as: UTF8.self)
}

extension Data {
    init(hex: String) {
        let digits = Array(hex.utf8)
        self.init(stride(from: 0, to: digits.count, by: 2).map {
            UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16)!
        })
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
