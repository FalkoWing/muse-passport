import Foundation
import Testing
@testable import PassportBridge

@Suite struct ReplyCacheTests {
    /// Replays every recorded scenario and compares each answer with the reference.
    @Test func scenariosMatchTheReference() throws {
        let root = try #require(try fixture("reply_cache") as? [String: Any])
        let scenarios = try #require(root["scenarios"] as? [String: [[String: Any]]])
        #expect(!scenarios.isEmpty)
        for (name, steps) in scenarios {
            var cache = ReplyCache()
            for (index, step) in steps.enumerated() {
                let label: Comment = "\(name), step \(index)"
                let fails = step["error"] != nil
                switch try #require(step["op"] as? String) {
                case "begin":
                    cache.begin()
                case "note":
                    cache.note(try #require(step["id"] as? String), replyTo: try #require(step["reply"] as? String))
                case "feed", "fill":
                    let data: Data
                    if let hex = step["hex"] as? String {
                        data = Data(hex: hex)
                    } else if let text = step["data"] as? String {
                        data = Data(text.utf8)
                    } else {
                        data = Data(repeating: UInt8(try #require(step["byte"] as? Int)),
                                    count: try #require(step["count"] as? Int))
                    }
                    if fails {
                        #expect(throws: ReplyCacheError.self, label) { try cache.feed(data) }
                    } else {
                        try cache.feed(data)
                    }
                case let op:
                    let path = try #require(step["path"] as? String)
                    let ask = { try op == "page" ? cache.page(path) : cache.readerPage(path) }
                    if fails {
                        #expect(throws: ReplyCacheError.self, label) { try ask() }
                    } else {
                        let answer = try canonical(JSONSerialization.jsonObject(with: try ask()))
                        let expected = try canonical(try #require(step["out"]))
                        #expect(answer == expected, label)
                    }
                }
            }
        }
    }

    @Test func wrappingMatchesTheReference() throws {
        let root = try #require(try fixture("reply_cache") as? [String: Any])
        let cases = try #require(root["wrap"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for item in cases {
            let text = try #require(item["text"] as? String)
            let pages = wrapPages(text, columns: try #require(item["cols"] as? Int),
                                  lines: try #require(item["lines"] as? Int))
            #expect(pages == item["pages"] as? [String], "\(text.prefix(20))")
        }
    }
}
