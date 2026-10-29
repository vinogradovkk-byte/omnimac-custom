import Foundation

/// Клиент GitLab только для чтения: единственный метод запроса — GET, токен нужен лишь со scope `read_api`.
/// Ничего, что меняет данные (POST/PUT/DELETE), здесь нет и не должно появляться.
struct GitLabClient {
    let credentials: GitLabCredentials
    var session: URLSession = .shared

    static func normalizedHost(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty, url.scheme == "https" || url.scheme == "http" else { return nil }
        return url
    }

    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: credentials.host, resolvingAgainstBaseURL: false) else { throw GitLabError.invalidHost }
        components.path += "/api/v4" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GitLabError.invalidHost }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue(credentials.token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw GitLabError.badResponse }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401: throw GitLabError.unauthorized
            case 403: throw GitLabError.forbidden
            default: throw GitLabError.http(http.statusCode)
            }
        } catch let error as GitLabError { throw error }
        catch { throw GitLabError.network(error.localizedDescription) }
    }

    /// Проверка токена; возвращает логин владельца.
    func currentUser() async throws -> GitLabUser {
        let (data, _) = try await send(try request("/user"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["username"] as? String, let id = object["id"] as? Int else { throw GitLabError.badResponse }
        return GitLabUser(id: id, username: name)
    }

    /// МР, где меня назначили ревьюером: открытые и вся история (смерженные и закрытые) за последние `days` дней,
    /// как и в разделе моих МР. Моя часть (лайк, апрув, комментарии) подгружается для каждого.
    func reviewRequests(me: GitLabUser, days: Int = 3, now: Date = Date()) async throws -> [GitLabMergeRequest] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let iso = ISO8601DateFormatter().string(from: cutoff)
        async let opened = reviewPage(me: me, state: "opened", updatedAfter: nil)
        async let merged = reviewPage(me: me, state: "merged", updatedAfter: iso)
        async let closed = reviewPage(me: me, state: "closed", updatedAfter: iso)
        let all = try await opened + Self.withinWindow(try await merged + closed, cutoff: cutoff)
        return await withThreads(all, me: me)
    }

    /// Смерженные и закрытые остаются, только если это случилось в окне (правка МР после слияния не считается).
    static func withinWindow(_ finished: [GitLabMergeRequest], cutoff: Date) -> [GitLabMergeRequest] {
        finished.filter { ($0.finishedAt ?? $0.updatedAt) >= cutoff }
    }

    private func reviewPage(me: GitLabUser, state: String, updatedAfter: String?) async throws -> [GitLabMergeRequest] {
        var result: [GitLabMergeRequest] = []
        var pageNumber = 1
        while pageNumber <= 5 {
            var query = [URLQueryItem(name: "scope", value: "all"), URLQueryItem(name: "state", value: state),
                         URLQueryItem(name: "reviewer_id", value: String(me.id)), URLQueryItem(name: "order_by", value: "updated_at"),
                         URLQueryItem(name: "sort", value: "desc"), URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(pageNumber))]
            if let updatedAfter { query.append(URLQueryItem(name: "updated_after", value: updatedAfter)) }
            let (data, http) = try await send(try request("/merge_requests", query: query))
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitLabError.badResponse }
            result += rows.compactMap(Self.mergeRequest(from:))
            guard let next = http.value(forHTTPHeaderField: "x-next-page"), !next.isEmpty else { break }
            pageNumber += 1
        }
        return result
    }

    /// Мои МР (где я автор): открытые + смерженные и закрытые за последние `days` дней.
    func myMergeRequests(days: Int = 3, now: Date = Date()) async throws -> [GitLabMergeRequest] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let iso = ISO8601DateFormatter().string(from: cutoff)
        async let opened = page(state: "opened", updatedAfter: nil)
        async let merged = page(state: "merged", updatedAfter: iso)
        async let closed = page(state: "closed", updatedAfter: iso)
        let all = try await opened + merged + closed
        return await withThreads(Self.filter(all, cutoff: cutoff))
    }

    /// Закрытые и смерженные — только если это случилось в окне (обновление МР после закрытия не считается).
    static func filter(_ requests: [GitLabMergeRequest], cutoff: Date) -> [GitLabMergeRequest] {
        requests.filter { $0.state == .opened || ($0.finishedAt ?? $0.updatedAt) >= cutoff }
            .sorted { ($0.finishedAt ?? $0.updatedAt) > ($1.finishedAt ?? $1.updatedAt) }
    }

    /// Решённые ветки обсуждений: один GET на МР с комментариями, по нескольку параллельно. Ошибки не мешают списку.
    private func withThreads(_ requests: [GitLabMergeRequest], me: GitLabUser? = nil) async -> [GitLabMergeRequest] {
        var result = requests
        let targets = requests.indices.filter { requests[$0].commentCount > 0 || requests[$0].state == .opened || me != nil }
        await withTaskGroup(of: (Int, ThreadStats?, Approval?, Date?, Date?).self) { group in
            var next = 0
            func launch() {
                guard next < targets.count else { return }
                let index = targets[next]; next += 1
                let mr = requests[index]
                group.addTask {
                    let threads = mr.commentCount > 0 ? try? await self.threadCounts(projectID: mr.projectID, iid: mr.iid, me: me) : nil
                    let approvals = (mr.state == .opened || me != nil) ? try? await self.approvalCounts(projectID: mr.projectID, iid: mr.iid, me: me) : nil
                    // Проверка «мной»: мой 👍 есть ли, и если проверен — дата последнего коммита.
                    var like: Date?
                    if let me { like = try? await self.myLike(projectID: mr.projectID, iid: mr.iid, me: me) }
                    var commit: Date?
                    if me != nil, mr.state == .opened, like != nil || approvals?.mine == true { commit = try? await self.lastCommit(projectID: mr.projectID, iid: mr.iid) }
                    return (index, threads, approvals, like, commit)
                }
            }
            for _ in 0..<min(6, targets.count) { launch() }
            for await (index, counts, approvals, like, commit) in group {
                if let counts {
                    result[index].resolvedThreads = counts.resolved; result[index].totalThreads = counts.total
                    result[index].myComments = counts.mine; result[index].myResolvedComments = counts.mineResolved
                }
                if let approvals {
                    result[index].approvals = approvals.count; result[index].approvalsRequired = approvals.required
                    result[index].iApproved = approvals.mine; result[index].myApprovalAt = approvals.mineAt
                }
                result[index].myLikeAt = like
                result[index].lastCommitAt = commit
                launch()
            }
        }
        return result
    }

    struct Approval { var count: Int; var required: Int?; var mine: Bool; var mineAt: Date? }

    private func approvalCounts(projectID: Int, iid: Int, me: GitLabUser?) async throws -> Approval {
        let (data, _) = try await send(try request("/projects/\(projectID)/merge_requests/\(iid)/approvals"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GitLabError.badResponse }
        return Self.approvalCounts(from: object, me: me)
    }

    static func approvalCounts(from object: [String: Any], me: GitLabUser? = nil) -> Approval {
        let by = object["approved_by"] as? [[String: Any]] ?? []
        let required = object["approvals_required"] as? Int
        let mine = by.first { ($0["user"] as? [String: Any])?["id"] as? Int == me?.id }
        return Approval(count: by.count, required: (required ?? 0) > 0 ? required : nil, mine: mine != nil, mineAt: date(mine?["approved_at"]))
    }

    /// Мой 👍 на МР: nil — не ставил, иначе дата, когда поставил.
    private func myLike(projectID: Int, iid: Int, me: GitLabUser) async throws -> Date? {
        let (data, _) = try await send(try request("/projects/\(projectID)/merge_requests/\(iid)/award_emoji", query: [URLQueryItem(name: "per_page", value: "100")]))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitLabError.badResponse }
        return Self.myLikeDate(in: rows, me: me)
    }

    static func myLikeDate(in rows: [[String: Any]], me: GitLabUser) -> Date? {
        rows.first { $0["name"] as? String == "thumbsup" && ($0["user"] as? [String: Any])?["id"] as? Int == me.id }
            .flatMap { date($0["created_at"]) }
    }

    /// Дата самого свежего коммита МР (GitLab отдаёт коммиты от новых к старым).
    private func lastCommit(projectID: Int, iid: Int) async throws -> Date? {
        let (data, _) = try await send(try request("/projects/\(projectID)/merge_requests/\(iid)/commits", query: [URLQueryItem(name: "per_page", value: "1")]))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitLabError.badResponse }
        return Self.date(rows.first?["committed_date"] ?? rows.first?["created_at"])
    }

    private func threadCounts(projectID: Int, iid: Int, me: GitLabUser?) async throws -> ThreadStats {
        let (data, _) = try await send(try request("/projects/\(projectID)/merge_requests/\(iid)/discussions", query: [URLQueryItem(name: "per_page", value: "100")]))
        guard let discussions = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitLabError.badResponse }
        return Self.threadStats(from: discussions, me: me)
    }

    struct ThreadStats { var resolved = 0, total = 0, mine = 0, mineResolved = 0 }

    /// Ветки обсуждений и мои комментарии: комментарий «решён», если решена вся его ветка.
    static func threadStats(from discussions: [[String: Any]], me: GitLabUser?) -> ThreadStats {
        var stats = ThreadStats()
        for discussion in discussions {
            let all = discussion["notes"] as? [[String: Any]] ?? []
            let resolvable = all.filter { $0["resolvable"] as? Bool == true }
            let threadResolved = !resolvable.isEmpty && resolvable.allSatisfy { $0["resolved"] as? Bool == true }
            if !resolvable.isEmpty { stats.total += 1; if threadResolved { stats.resolved += 1 } }
            guard let me else { continue }
            let mine = all.filter { $0["system"] as? Bool != true && ($0["author"] as? [String: Any])?["id"] as? Int == me.id }.count
            stats.mine += mine
            if threadResolved { stats.mineResolved += mine }
        }
        return stats
    }

    /// Считаются только решаемые ветки (обычные комментарии и системные заметки не в счёт).
    static func threadCounts(from discussions: [[String: Any]]) -> (resolved: Int, total: Int) {
        var resolved = 0, total = 0
        for discussion in discussions {
            let notes = (discussion["notes"] as? [[String: Any]] ?? []).filter { $0["resolvable"] as? Bool == true }
            guard !notes.isEmpty else { continue }
            total += 1
            if notes.allSatisfy({ $0["resolved"] as? Bool == true }) { resolved += 1 }
        }
        return (resolved, total)
    }

    private func page(state: String, updatedAfter: String?) async throws -> [GitLabMergeRequest] {
        var result: [GitLabMergeRequest] = []
        var pageNumber = 1
        while pageNumber <= 5 {
            var query = [URLQueryItem(name: "scope", value: "created_by_me"), URLQueryItem(name: "state", value: state),
                         URLQueryItem(name: "order_by", value: "updated_at"), URLQueryItem(name: "sort", value: "desc"),
                         URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "page", value: String(pageNumber))]
            if let updatedAfter { query.append(URLQueryItem(name: "updated_after", value: updatedAfter)) }
            let (data, http) = try await send(try request("/merge_requests", query: query))
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw GitLabError.badResponse }
            result += rows.compactMap(Self.mergeRequest(from:))
            guard let next = http.value(forHTTPHeaderField: "x-next-page"), !next.isEmpty else { break }
            pageNumber += 1
        }
        return result
    }

    static func mergeRequest(from row: [String: Any]) -> GitLabMergeRequest? {
        guard let id = row["id"] as? Int, let title = row["title"] as? String,
              let stateText = row["state"] as? String, let state = GitLabMergeRequest.State(rawValue: stateText),
              let web = (row["web_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let author = (row["author"] as? [String: Any])?["name"] as? String ?? ""
        let reference = (row["references"] as? [String: Any])?["full"] as? String ?? "!\(row["iid"] as? Int ?? 0)"
        let finished = (state == .merged ? row["merged_at"] : row["closed_at"]) as? String
        let pipeline = row["head_pipeline"] as? [String: Any]
        return GitLabMergeRequest(
            id: id, iid: row["iid"] as? Int ?? 0, projectID: row["project_id"] as? Int ?? 0, title: title, state: state, webURL: web, reference: reference, author: author,
            isDraft: row["draft"] as? Bool ?? row["work_in_progress"] as? Bool ?? false,
            sourceBranch: row["source_branch"] as? String ?? "", targetBranch: row["target_branch"] as? String ?? "",
            createdAt: date(row["created_at"]) ?? .distantPast, updatedAt: date(row["updated_at"]) ?? .distantPast,
            finishedAt: state == .opened ? nil : date(finished),
            commentCount: row["user_notes_count"] as? Int ?? 0,
            hasConflicts: row["has_conflicts"] as? Bool ?? false,
            pipelineStatus: pipeline?["status"] as? String, pipelineURL: (pipeline?["web_url"] as? String).flatMap(URL.init(string:)),
            upvotes: row["upvotes"] as? Int ?? 0, downvotes: row["downvotes"] as? Int ?? 0)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}
