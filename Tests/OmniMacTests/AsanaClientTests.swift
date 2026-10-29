import XCTest
@testable import OmniMac

final class AsanaClientTests: XCTestCase {
    func testTaskIsBuiltFromListRowWithStatusAndCustomFields() {
        let row: [String: Any] = [
            "gid": "1", "name": "Исправить промокоды", "completed": false, "due_on": "2026-10-20", "num_subtasks": 2,
            "memberships": [["project": ["gid": "P", "name": "A&R Delivery"], "section": ["name": "Code review"]]],
            "custom_fields": [["name": "FTP", "display_value": "FTP-5630"], ["name": "Тип задачи", "display_value": "Баг"],
                              ["name": "Приоритет (Team)", "display_value": "Высокий"], ["name": "QA", "display_value": ""]]]
        let task = AsanaClient.task(from: row)
        XCTAssertEqual(task?.status, "Code review")
        XCTAssertEqual(task?.ftpKey, "FTP-5630")
        XCTAssertEqual(task?.priority, "Высокий")
        XCTAssertNil(task?.qa)   // пустое значение поля не показываем
    }

    func testCompletedTaskIsDroppedAndMissingSectionMeansNoStatus() {
        XCTAssertNil(AsanaClient.task(from: ["gid": "1", "name": "x", "completed": true]))
        XCTAssertEqual(AsanaClient.task(from: ["gid": "2", "name": "y", "completed": false, "memberships": []])?.status, AsanaClient.noStatus)
    }

    func testOnlyHumanCommentsAreKept() {
        let stories: [[String: Any]] = [
            ["gid": "1", "type": "comment", "resource_subtype": "comment_added", "text": "Проверил", "created_by": ["name": "Ramina"]],
            ["gid": "2", "type": "system", "resource_subtype": "section_changed", "text": "moved to Code review"]]
        XCTAssertEqual(AsanaClient.comments(from: stories).map(\.text), ["Проверил"])
    }

    func testStatusesFollowBoardOrderWithNoStatusLast() {
        let order = ["Backlog", "To do", "In progress", "Code review"]
        let result = AsanaStore.orderedStatuses(present: ["Code review", AsanaClient.noStatus, "Custom", "To do"], order: order)
        XCTAssertEqual(result, ["To do", "Code review", "Custom", AsanaClient.noStatus])
    }
}

final class AsanaLinksTests: XCTestCase {
    func testAttachmentAndLinkParsing() {
        let file = AsanaClient.attachment(from: ["gid": "1", "name": "ошибка.png", "size": 2048, "host": "asana", "permalink_url": "https://app.asana.com/0/1/2/f"])
        XCTAssertEqual(file?.iconName, "photo")
        XCTAssertEqual(file?.size, 2048)
        XCTAssertEqual(AsanaClient.attachment(from: ["gid": "2", "name": "Спека", "host": "google"])?.iconName, "link")
        let parent = AsanaClient.link(from: ["gid": "9", "name": "Эпик", "permalink_url": "https://app.asana.com/0/1/9"])
        XCTAssertEqual(parent?.name, "Эпик")
        XCTAssertNil(AsanaClient.link(from: nil))
        let sub = AsanaClient.subtask(from: ["gid": "3", "name": "Тест", "completed": true, "permalink_url": "https://app.asana.com/0/1/3"])
        XCTAssertEqual(sub?.url?.absoluteString, "https://app.asana.com/0/1/3")
    }
}

final class AsanaUploadTests: XCTestCase {
    func testMultipartBodyHasParentAndFileParts() {
        let body = AsanaClient.multipartBody(boundary: "B", parent: "123", fileName: "a\"b.txt", data: Data("hello".utf8))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"parent\"\r\n\r\n123\r\n"))
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"a_b.txt\""))   // кавычка в имени не ломает заголовок
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
    }
}

final class AsanaCommentFilesTests: XCTestCase {
    private func story(_ gid: String, subtype: String, type: String = "system", text: String? = nil, author: String = "Кирилл", at: String, files: [[String: Any]] = []) -> [String: Any] {
        var row: [String: Any] = ["gid": gid, "type": type, "resource_subtype": subtype, "created_by": ["name": author], "created_at": at, "attachments": files]
        if let text { row["text"] = text }
        return row
    }

    func testFileAddedRightAfterACommentBelongsToThatComment() {
        let file: [String: Any] = ["gid": "f1", "name": "скрин.png", "size": 100, "host": "asana"]
        let stories = [
            story("1", subtype: "comment_added", type: "comment", text: "привет", at: "2026-10-27T12:00:00.000Z"),
            story("2", subtype: "attachment_added", at: "2026-10-27T12:00:03.000Z", files: [file]),
            story("3", subtype: "attachment_added", author: "Другой", at: "2026-10-27T12:00:05.000Z", files: [file]),   // другой автор
            story("4", subtype: "attachment_added", at: "2026-10-27T13:00:00.000Z", files: [file])                       // слишком поздно
        ]
        let result = AsanaClient.comments(from: stories)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].attachments.map(\.name), ["скрин.png"])
        XCTAssertTrue(result[1].text.isEmpty && result[1].attachments.count == 1)
        XCTAssertTrue(result[2].text.isEmpty && result[2].attachments.count == 1)
    }

    func testSystemStoriesAreStillIgnored() {
        XCTAssertTrue(AsanaClient.comments(from: [story("1", subtype: "section_changed", at: "2026-10-27T12:00:00.000Z")]).isEmpty)
    }
}
