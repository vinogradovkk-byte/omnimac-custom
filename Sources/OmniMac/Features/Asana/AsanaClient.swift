import Foundation

/// Клиент Asana. Читает данные через GET; записи только две и обе запускает пользователь: комментарий (`postComment`)
/// и файл-вложение к задаче (`uploadAttachment`). Других изменяющих запросов здесь нет и не должно появляться без отдельной просьбы.
struct AsanaClient {
    let token: String
    var session: URLSession = .shared
    /// Адрес API. Для проверок без настоящего аккаунта можно подменить на локальный сервер (только localhost), токен никуда больше не уйдёт.
    static var base: URL {
        if let text = UserDefaults.standard.string(forKey: "asana.testBase"), let url = URL(string: text), ["127.0.0.1", "localhost"].contains(url.host) { return url }
        return URL(string: "https://app.asana.com/api/1.0")!
    }

    private func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AsanaError.badResponse }
            switch http.statusCode {
            case 200..<300: break
            case 401: throw AsanaError.unauthorized
            case 403: throw AsanaError.forbidden
            case 429: throw AsanaError.rateLimited
            default: throw AsanaError.http(http.statusCode)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AsanaError.badResponse }
            return object
        } catch let error as AsanaError { throw error }
        catch { throw AsanaError.network(error.localizedDescription) }
    }

    /// Единственный запрос на запись: новый комментарий в задаче. Возвращает созданный комментарий.
    func postComment(taskGID: String, text: String) async throws -> AsanaComment {
        let url = Self.base.appendingPathComponent("tasks/\(taskGID)/stories")
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": ["text": text]])
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AsanaError.badResponse }
            switch http.statusCode {
            case 200..<300: break
            case 401: throw AsanaError.unauthorized
            case 403: throw AsanaError.forbidden
            case 429: throw AsanaError.rateLimited
            default: throw AsanaError.http(http.statusCode)
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let row = object["data"] as? [String: Any], let gid = row["gid"] as? String else { throw AsanaError.badResponse }
            return AsanaComment(id: gid, author: (row["created_by"] as? [String: Any])?["name"] as? String ?? "—",
                                text: row["text"] as? String ?? text, createdAt: Self.date(row["created_at"]))
        } catch let error as AsanaError { throw error }
        catch { throw AsanaError.network(error.localizedDescription) }
    }

    /// Asana принимает вложения до 100 МБ.
    static let maxAttachmentBytes = 100 * 1024 * 1024

    /// Загружает файл как вложение задачи (multipart/form-data) и возвращает созданное вложение.
    func uploadAttachment(taskGID: String, fileURL: URL) async throws -> AsanaAttachment {
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maxAttachmentBytes else { throw AsanaError.http(413) }
        let boundary = "omnimac-\(UUID().uuidString)"
        var components = URLComponents(url: Self.base.appendingPathComponent("attachments"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "opt_fields", value: "name,permalink_url,view_url,download_url,size,host,created_at")]
        var request = URLRequest(url: components.url!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.multipartBody(boundary: boundary, parent: taskGID, fileName: fileURL.lastPathComponent, data: data)
        do {
            let (response, http) = try await session.data(for: request)
            guard let status = (http as? HTTPURLResponse)?.statusCode else { throw AsanaError.badResponse }
            switch status {
            case 200..<300: break
            case 401: throw AsanaError.unauthorized
            case 403: throw AsanaError.forbidden
            case 429: throw AsanaError.rateLimited
            default: throw AsanaError.http(status)
            }
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let row = object["data"] as? [String: Any], let attachment = Self.attachment(from: row) else { throw AsanaError.badResponse }
            return attachment
        } catch let error as AsanaError { throw error }
        catch { throw AsanaError.network(error.localizedDescription) }
    }

    static func multipartBody(boundary: String, parent: String, fileName: String, data: Data) -> Data {
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"parent\"\r\n\r\n\(parent)\r\n")
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        body.append(data)
        add("\r\n--\(boundary)--\r\n")
        return body
    }

    /// Все страницы списка (Asana отдаёт `next_page.offset`).
    private func getAll(_ path: String, _ query: [String: String]) async throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var query = query; query["limit"] = "100"
        for _ in 0..<10 {
            let object = try await get(path, query)
            rows += object["data"] as? [[String: Any]] ?? []
            guard let offset = (object["next_page"] as? [String: Any])?["offset"] as? String else { break }
            query["offset"] = offset
        }
        return rows
    }

    struct Me { let gid: String; let name: String; let workspaces: [String] }

    func me() async throws -> Me {
        let data = (try await get("users/me", ["opt_fields": "name,workspaces.gid"]))["data"] as? [String: Any]
        guard let gid = data?["gid"] as? String else { throw AsanaError.badResponse }
        let spaces = (data?["workspaces"] as? [[String: Any]] ?? []).compactMap { $0["gid"] as? String }
        return Me(gid: gid, name: data?["name"] as? String ?? "", workspaces: spaces)
    }

    private static let listFields = "name,due_on,completed,permalink_url,modified_at,completed_at,num_subtasks,memberships.project.gid,memberships.project.name,memberships.section.name,parent.name,custom_fields.name,custom_fields.display_value"

    /// Мои незавершённые задачи со всех рабочих пространств, со статусами (колонками доски).
    func myTasks() async throws -> (tasks: [AsanaTask], sectionOrder: [String], doneToday: Int) {
        let me = try await self.me()
        guard !me.workspaces.isEmpty else { throw AsanaError.noWorkspace }
        var tasks: [AsanaTask] = []
        var projects: [String] = []
        var doneToday = 0
        let startOfDay = Calendar.current.startOfDay(for: Date())
        for workspace in me.workspaces {
            let list = (try await get("users/me/user_task_list", ["workspace": workspace]))["data"] as? [String: Any]
            guard let listGID = list?["gid"] as? String else { continue }
            let rows = try await getAll("user_task_lists/\(listGID)/tasks", ["completed_since": Self.plain.string(from: startOfDay), "opt_fields": Self.listFields])
            for row in rows {
                if let task = Self.task(from: row) { tasks.append(task) }
                // completed_since devuelve también lo cerrado desde esa fecha: así sale el contador de «hechas hoy».
                else if row["completed"] as? Bool == true, let at = Self.date(row["completed_at"]), at >= startOfDay { doneToday += 1 }
                for membership in row["memberships"] as? [[String: Any]] ?? [] {
                    if let gid = (membership["project"] as? [String: Any])?["gid"] as? String, !projects.contains(gid) { projects.append(gid) }
                }
            }
        }
        // Порядок колонок как на доске проекта.
        var order: [String] = []
        for project in projects {
            let rows = (try? await getAll("projects/\(project)/sections", ["opt_fields": "name"])) ?? []
            for name in rows.compactMap({ $0["name"] as? String }) where !order.contains(name) { order.append(name) }
        }
        return (tasks, order, doneToday)
    }

    static let noStatus = "—"

    static func task(from row: [String: Any]) -> AsanaTask? {
        guard let gid = row["gid"] as? String, let name = row["name"] as? String, row["completed"] as? Bool != true else { return nil }
        let membership = (row["memberships"] as? [[String: Any]] ?? []).first { ($0["section"] as? [String: Any])?["name"] != nil }
        let status = (membership?["section"] as? [String: Any])?["name"] as? String ?? noStatus
        let project = (membership?["project"] as? [String: Any])?["name"] as? String
        let fields = row["custom_fields"] as? [[String: Any]] ?? []
        func field(_ name: String) -> String? {
            let value = fields.first { ($0["name"] as? String)?.hasPrefix(name) == true }?["display_value"] as? String
            return (value?.isEmpty ?? true) ? nil : value
        }
        return AsanaTask(id: gid, name: name, status: status, project: project, dueOn: row["due_on"] as? String,
                         permalink: (row["permalink_url"] as? String).flatMap(URL.init(string:)),
                         ftpKey: field("FTP"), taskType: field("Тип задачи"), priority: field("Приоритет"), qa: field("QA"),
                         subtaskCount: row["num_subtasks"] as? Int ?? 0, modifiedAt: date(row["modified_at"]),
                         parentName: (row["parent"] as? [String: Any])?["name"] as? String)
    }

    // MARK: - Подробности задачи (по раскрытию строки)

    func detail(of taskGID: String) async throws -> AsanaTaskDetail {
        async let task = get("tasks/\(taskGID)", ["opt_fields": "name,completed,due_on,assignee.name,permalink_url,memberships.project.name,memberships.section.name,notes,created_at,created_by.name,tags.name,custom_fields.name,custom_fields.display_value,parent.name,parent.permalink_url,parent.completed"])
        async let subtasks = getAll("tasks/\(taskGID)/subtasks", ["opt_fields": "name,completed,assignee.name,permalink_url"])
        async let attachments = getAll("tasks/\(taskGID)/attachments", ["opt_fields": "name,permalink_url,view_url,download_url,size,host,created_at,resource_subtype"])
        async let blockedBy = getAll("tasks/\(taskGID)/dependencies", ["opt_fields": "name,completed,permalink_url"])
        async let blocking = getAll("tasks/\(taskGID)/dependents", ["opt_fields": "name,completed,permalink_url"])
        async let stories = getAll("tasks/\(taskGID)/stories", ["opt_fields": "created_at,created_by.name,text,type,resource_subtype,attachments.name,attachments.permalink_url,attachments.view_url,attachments.download_url,attachments.size,attachments.host,attachments.created_at"])
        let data = (try await task)["data"] as? [String: Any] ?? [:]
        let fields = (data["custom_fields"] as? [[String: Any]] ?? []).compactMap { field -> (String, String)? in
            guard let name = field["name"] as? String, let value = field["display_value"] as? String, !value.isEmpty else { return nil }
            return (name, value)
        }
        let membership = (data["memberships"] as? [[String: Any]] ?? []).first { ($0["section"] as? [String: Any])?["name"] != nil }
        return AsanaTaskDetail(
            name: data["name"] as? String ?? "", completed: data["completed"] as? Bool ?? false,
            assignee: (data["assignee"] as? [String: Any])?["name"] as? String, dueOn: data["due_on"] as? String,
            status: (membership?["section"] as? [String: Any])?["name"] as? String,
            project: (membership?["project"] as? [String: Any])?["name"] as? String,
            permalink: (data["permalink_url"] as? String).flatMap(URL.init(string:)),
            notes: (data["notes"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            createdBy: (data["created_by"] as? [String: Any])?["name"] as? String,
            createdAt: Self.date(data["created_at"]),
            tags: (data["tags"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String },
            fields: fields,
            subtasks: (try await subtasks).compactMap(Self.subtask(from:)),
            comments: Self.comments(from: try await stories),
            // Вложения и связи — второстепенное: если Asana не отдала их, окно с описанием всё равно показываем.
            attachments: ((try? await attachments) ?? []).compactMap(Self.attachment(from:)),
            parent: Self.link(from: data["parent"] as? [String: Any]),
            blockedBy: ((try? await blockedBy) ?? []).compactMap { Self.link(from: $0) },
            blocking: ((try? await blocking) ?? []).compactMap { Self.link(from: $0) })
    }

    static func subtask(from row: [String: Any]) -> AsanaSubtask? {
        guard let gid = row["gid"] as? String, let name = row["name"] as? String else { return nil }
        return AsanaSubtask(id: gid, name: name, completed: row["completed"] as? Bool ?? false, assignee: (row["assignee"] as? [String: Any])?["name"] as? String,
                            url: (row["permalink_url"] as? String).flatMap(URL.init(string:)))
    }

    static func link(from row: [String: Any]?) -> AsanaLink? {
        guard let row, let gid = row["gid"] as? String, let name = row["name"] as? String else { return nil }
        return AsanaLink(id: gid, name: name, url: (row["permalink_url"] as? String).flatMap(URL.init(string:)), completed: row["completed"] as? Bool ?? false)
    }

    static func attachment(from row: [String: Any]) -> AsanaAttachment? {
        guard let gid = row["gid"] as? String, let name = row["name"] as? String else { return nil }
        let link = (row["permalink_url"] as? String) ?? (row["view_url"] as? String)
        return AsanaAttachment(id: gid, name: name, downloadURL: (row["download_url"] as? String).flatMap(URL.init(string:)),
                               url: link.flatMap(URL.init(string:)), size: row["size"] as? Int,
                               host: row["host"] as? String ?? "asana", createdAt: date(row["created_at"]))
    }

    /// Комментарии людей и прикреплённые файлы. Системные записи («переместил в колонку…») не нужны, кроме «прикрепил файл»:
    /// Asana не связывает вложение с комментарием, поэтому файл, добавленный тем же автором сразу после комментария
    /// (до двух минут), показываем внутри этого комментария, остальные — отдельной записью без текста.
    static func comments(from stories: [[String: Any]], groupWithin seconds: TimeInterval = 120) -> [AsanaComment] {
        var result: [AsanaComment] = []
        for row in stories {
            let author = (row["created_by"] as? [String: Any])?["name"] as? String ?? "—"
            let created = date(row["created_at"])
            if row["type"] as? String == "comment" || row["resource_subtype"] as? String == "comment_added",
               let gid = row["gid"] as? String, let text = row["text"] as? String, !text.isEmpty {
                result.append(AsanaComment(id: gid, author: author, text: text, createdAt: created))
            } else if row["resource_subtype"] as? String == "attachment_added" {
                let files = (row["attachments"] as? [[String: Any]] ?? []).compactMap(attachment(from:))
                guard !files.isEmpty, let gid = row["gid"] as? String else { continue }
                if var last = result.last, last.author == author, let a = last.createdAt, let b = created, b.timeIntervalSince(a) <= seconds, b >= a {
                    last.attachments += files; result[result.count - 1] = last
                } else {
                    result.append(AsanaComment(id: gid, author: author, text: "", createdAt: created, attachments: files))
                }
            }
        }
        return result
    }

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}
