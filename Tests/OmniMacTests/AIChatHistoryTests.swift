import XCTest
@testable import OmniMac

final class AIChatHistoryTests: XCTestCase {
    func testClaudeSummaryAndTranscriptSkipNoise() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("-proj"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","cwd":"/x","message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>x</ide_opened_file>"},{"type":"text","text":"Привет"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Здравствуйте"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"skip"}]}}"#
        ].joined(separator: "\n")
        try lines.write(to: folder.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)
        let sessions = ClaudeHistory.sessions(in: root)
        XCTAssertEqual(sessions.first?.title, "Привет"); XCTAssertEqual(sessions.first?.root, "/x")
        XCTAssertEqual(ClaudeHistory.transcript(id: "abc", in: root).map(\.text), ["Привет", "Здравствуйте"])
    }

    func testCodexTranscriptKeepsOnlyMessages() {
        let result: [String: Any] = ["thread": ["turns": [["items": [
            ["type": "userMessage", "content": [["type": "text", "text": "q"]]],
            ["type": "commandExecution"], ["type": "agentMessage", "text": "a"]]]]]]
        XCTAssertEqual(CodexProtocol.transcript(from: result).map(\.text), ["q", "a"])
    }
}
