import XCTest
@testable import OmniMac

final class GitLabClientTests: XCTestCase {
    private func row(_ id: Int, state: String, merged: String? = nil, closed: String? = nil, updated: String = "2026-10-23T10:00:00.000Z") -> [String: Any] {
        ["id": id, "iid": id, "title": "MR \(id)", "state": state, "web_url": "https://gitlab.com/g/p/-/merge_requests/\(id)",
         "references": ["full": "g/p!\(id)"], "author": ["name": "Me"], "created_at": "2026-10-01T10:00:00.000Z",
         "updated_at": updated, "merged_at": merged as Any, "closed_at": closed as Any]
    }

    func testParsesFractionalAndPlainDates() {
        XCTAssertNotNil(GitLabClient.date("2026-10-23T10:00:00.000Z"))
        XCTAssertNotNil(GitLabClient.date("2026-10-23T10:00:00Z"))
        XCTAssertNil(GitLabClient.date(nil))
    }

    func testWindowKeepsOpenAndRecentFinishedOnly() throws {
        let now = GitLabClient.date("2026-10-23T12:00:00Z")!
        let requests = [
            row(1, state: "opened", updated: "2026-09-01T00:00:00Z"),
            row(2, state: "merged", merged: "2026-10-22T09:00:00Z"),
            row(3, state: "merged", merged: "2026-10-10T09:00:00Z", updated: "2026-10-23T09:00:00Z"),  // обновлён позже, но слит давно
            row(4, state: "closed", closed: "2026-10-21T13:00:00Z")
        ].compactMap(GitLabClient.mergeRequest(from:))
        let kept = GitLabClient.filter(requests, cutoff: now.addingTimeInterval(-3 * 86_400))
        XCTAssertEqual(Set(kept.map(\.id)), [1, 2, 4])
    }

    func testHostNormalization() {
        XCTAssertEqual(GitLabClient.normalizedHost("gitlab.com/")?.absoluteString, "https://gitlab.com")
        XCTAssertEqual(GitLabClient.normalizedHost(" http://127.0.0.1:8765 ")?.absoluteString, "http://127.0.0.1:8765")
        XCTAssertNil(GitLabClient.normalizedHost(""))
        XCTAssertNil(GitLabClient.normalizedHost("ftp://x"))
    }

    private func review(_ id: Int, like: String? = nil, approved: Bool = false, approvedAt: String? = nil, commit: String? = nil) -> GitLabMergeRequest {
        var mr = GitLabClient.mergeRequest(from: row(id, state: "opened"))!
        mr.myLikeAt = like.flatMap(GitLabClient.date); mr.iApproved = approved
        mr.myApprovalAt = approvedAt.flatMap(GitLabClient.date); mr.lastCommitAt = commit.flatMap(GitLabClient.date)
        return mr
    }

    func testReviewedMergeRequestGoesDownUntilNewCommit() {
        let fresh = review(1)
        let liked = review(2, like: "2026-10-22T10:00:00Z", approved: true, commit: "2026-10-21T10:00:00Z")
        let recheck = review(3, like: "2026-10-22T10:00:00Z", approved: true, commit: "2026-10-23T08:00:00Z")
        XCTAssertFalse(fresh.isDoneForMe)
        XCTAssertTrue(liked.isDoneForMe)
        XCTAssertTrue(recheck.needsRecheck)
        XCTAssertFalse(recheck.isDoneForMe)
        let order = GitLabStore.sortedForReview([liked, fresh, recheck]).map(\.id)
        XCTAssertEqual(Set(order.prefix(2)), [1, 3])
        XCTAssertEqual(order.last, 2)
    }

    func testMyLikeAndApprovalAreReadForTheCurrentUserOnly() {
        let me = GitLabUser(id: 7, username: "me")
        let likes: [[String: Any]] = [["name": "thumbsup", "user": ["id": 8], "created_at": "2026-10-22T10:00:00Z"],
                                      ["name": "thumbsup", "user": ["id": 7], "created_at": "2026-10-22T11:30:00Z"]]
        XCTAssertEqual(GitLabClient.myLikeDate(in: likes, me: me), GitLabClient.date("2026-10-22T11:30:00Z"))
        let approval = GitLabClient.approvalCounts(from: ["approved_by": [["user": ["id": 7]], ["user": ["id": 9]]], "approvals_required": 2], me: me)
        XCTAssertTrue(approval.mine)
        XCTAssertEqual(approval.count, 2)
    }

    func testReviewHistoryKeepsEveryMergedAndClosedInTheWindow() {
        let cutoff = GitLabClient.date("2026-10-20T00:00:00Z")!
        let recent = GitLabClient.mergeRequest(from: row(1, state: "merged", merged: "2026-10-22T20:00:00Z"))!
        let recentClosed = GitLabClient.mergeRequest(from: row(2, state: "closed", closed: "2026-10-21T20:00:00Z"))!
        let old = GitLabClient.mergeRequest(from: row(3, state: "merged", merged: "2026-10-10T20:00:00Z", updated: "2026-10-22T20:00:00Z"))!
        let kept = GitLabClient.withinWindow([recent, recentClosed, old], cutoff: cutoff)
        XCTAssertEqual(kept.map(\.id), [1, 2])          // без лайка и комментариев тоже; слитый давно — нет
        XCTAssertTrue(recent.isDoneForMe && recentClosed.isDoneForMe)
    }
}

final class GitLabBranchGroupTests: XCTestCase {
    private func mr(_ id: Int, ref: String, src: String) -> GitLabMergeRequest {
        var json: [String: Any] = ["id": id, "iid": id, "title": "t", "state": "opened", "web_url": "https://x/\(id)", "references": ["full": ref],
                                   "source_branch": src, "target_branch": "main", "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-23T10:00:00Z"]
        json["project_id"] = 1
        return GitLabClient.mergeRequest(from: json)!
    }

    func testRepositoryIsTakenFromTheReference() {
        XCTAssertEqual(mr(1, ref: "team/backend!12", src: "a").projectPath, "team/backend")
        XCTAssertEqual(mr(2, ref: "group/sub/project!9", src: "a").projectName, "project")
    }

    func testGroupsBySourceBranchKeepingFirstSeenOrder() {
        let items = [mr(1, ref: "t/back!1", src: "feat/FTP-1"), mr(2, ref: "t/front!2", src: "feat/FTP-2"), mr(3, ref: "t/front!3", src: "feat/FTP-1")]
        let groups = GitLabStore.groupedBySourceBranch(items)
        XCTAssertEqual(groups.map(\.branch), ["feat/FTP-1", "feat/FTP-2"])
        XCTAssertEqual(groups[0].items.map(\.id), [1, 3])
        XCTAssertEqual(groups[0].repositories, ["t/back", "t/front"])
    }
}

final class GitLabBranchOrderTests: XCTestCase {
    private func mr(_ id: Int, src: String, state: String) -> GitLabMergeRequest {
        GitLabClient.mergeRequest(from: ["id": id, "iid": id, "project_id": 1, "title": "t", "state": state, "web_url": "https://x/\(id)",
            "references": ["full": "g/p!\(id)"], "source_branch": src, "target_branch": "main",
            "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-23T10:00:00Z"])!
    }

    func testBranchStaysActiveWhileItHasAnOpenMergeRequestAndFinishedOnesGoDown() {
        let items = [mr(1, src: "A", state: "merged"), mr(2, src: "B", state: "opened"), mr(3, src: "A", state: "opened"),
                     mr(4, src: "C", state: "closed"), mr(5, src: "C", state: "merged")]
        let result = GitLabStore.orderedGroups(items) { $0.state == .opened }
        XCTAssertEqual(result.active.map(\.branch), ["A", "B"])
        XCTAssertEqual(result.active[0].items.map(\.id), [3, 1])   // открытый выше смерженного
        XCTAssertEqual(result.finished.map(\.branch), ["C"])
    }
}

final class GitLabReviewRuleTests: XCTestCase {
    private func open(_ id: Int, src: String, like: Bool = false, approved: Bool = false, state: String = "opened") -> GitLabMergeRequest {
        var mr = GitLabClient.mergeRequest(from: ["id": id, "iid": id, "project_id": 1, "title": "t", "state": state, "web_url": "https://x/\(id)",
            "references": ["full": "g/p!\(id)"], "source_branch": src, "target_branch": "main",
            "created_at": "2026-10-01T00:00:00Z", "updated_at": "2026-10-23T10:00:00Z"])!
        if like { mr.myLikeAt = GitLabClient.date("2026-10-22T10:00:00Z") }
        mr.iApproved = approved
        return mr
    }

    func testOpenMergeRequestNeedsBothLikeAndApproval() {
        XCTAssertFalse(open(1, src: "A").isDoneForMe)
        XCTAssertFalse(open(2, src: "A", like: true).isDoneForMe)
        XCTAssertFalse(open(3, src: "A", approved: true).isDoneForMe)
        XCTAssertTrue(open(4, src: "A", like: true, approved: true).isDoneForMe)
        XCTAssertTrue(open(5, src: "A", state: "merged").isDoneForMe)
    }

    func testBranchGoesDownOnlyWhenEveryMergeRequestIsDone() {
        let done = open(1, src: "A", like: true, approved: true)
        let merged = open(2, src: "A", state: "merged")
        let half = open(3, src: "B", like: true)                    // только лайк: ветка остаётся наверху
        let result = GitLabStore.orderedGroups([done, merged, half]) { !$0.isDoneForMe }
        XCTAssertEqual(result.active.map(\.branch), ["B"])
        XCTAssertEqual(result.finished.map(\.branch), ["A"])
    }
}
