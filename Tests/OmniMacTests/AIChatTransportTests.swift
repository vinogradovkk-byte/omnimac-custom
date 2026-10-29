import XCTest
@testable import OmniMac

final class AIProviderEventTests: XCTestCase {
    func testProviderCanSelectNewConversation() {
        let event = AIProviderEvent.conversationSelected("thread-42")
        guard case .conversationSelected(let id) = event else {
            return XCTFail("Expected conversationSelected event")
        }
        XCTAssertEqual(id, "thread-42")
    }
}

final class AIChatTransportTests: XCTestCase {
    func testDecoderRetainsPartialLine() throws {
        var decoder = JSONLineDecoder()
        XCTAssertTrue(try decoder.feed(Data("{\"id\":1".utf8)).isEmpty)
        let values = try decoder.feed(Data("}\n".utf8))
        XCTAssertEqual((values.first as? [String: Any])?["id"] as? Int, 1)
    }

    func testDecoderReturnsEveryCompleteLine() throws {
        var decoder = JSONLineDecoder()
        let values = try decoder.feed(Data("{\"id\":1}\n{\"id\":2}\n".utf8))
        XCTAssertEqual(values.count, 2)
    }

    func testProcessSpecificationKeepsArgumentsLiteral() {
        let specification = ProviderProcessSpecification(
            executable: URL(fileURLWithPath: "/usr/bin/example"),
            arguments: ["question; rm -rf /", "$(whoami)"]
        )
        XCTAssertEqual(specification.arguments, ["question; rm -rf /", "$(whoami)"])
        XCTAssertEqual(specification.executable.path, "/usr/bin/example")
    }

    func testStderrBufferIsBounded() {
        var buffer = BoundedDataBuffer(limit: 5)
        buffer.append(Data("1234".utf8))
        buffer.append(Data("5678".utf8))
        XCTAssertEqual(String(data: buffer.data, encoding: .utf8), "45678")
    }
}
