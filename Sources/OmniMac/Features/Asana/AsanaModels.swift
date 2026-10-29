import Foundation

struct AsanaTask: Identifiable, Equatable {
    let id: String            // gid
    let name: String
    let status: String        // колонка доски (section) или «Без статуса»
    let project: String?
    let dueOn: String?        // yyyy-MM-dd
    let permalink: URL?
    let ftpKey: String?
    let taskType: String?
    let priority: String?
    let qa: String?
    let subtaskCount: Int
    let modifiedAt: Date?
    /// Если сама задача — подзадача: название родителя (для значка в строке).
    let parentName: String?
}

/// Ссылка на другую задачу Asana с названием: родитель, зависимость и т.п.
struct AsanaLink: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL?
    let completed: Bool
}

struct AsanaAttachment: Identifiable, Equatable {
    let id: String
    let name: String
    /// Прямая ссылка на файл (для миниатюры картинок); живёт недолго, поэтому для открытия используем `url`.
    var downloadURL: URL? = nil
    let url: URL?          // страница вложения в Asana (адрес для скачивания живёт недолго, поэтому открываем страницу)
    let size: Int?
    let host: String       // asana, google, dropbox, box, external…
    let createdAt: Date?

    var isImage: Bool { ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"].contains((name as NSString).pathExtension.lowercased()) }

    var iconName: String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg"].contains(ext) { return "photo" }
        if ["pdf"].contains(ext) { return "doc.richtext" }
        if ["zip", "gz", "tar", "rar", "7z"].contains(ext) { return "doc.zipper" }
        if ["xls", "xlsx", "csv"].contains(ext) { return "tablecells" }
        if ["mov", "mp4", "avi", "mkv"].contains(ext) { return "film" }
        if host != "asana" { return "link" }
        return "doc"
    }
}

struct AsanaTaskDetail: Equatable {
    /// Шапка страницы задачи (нужна, когда открыта подзадача или связанная задача, которой нет в моём списке).
    var name: String = ""
    var completed = false
    var assignee: String?
    var dueOn: String?
    var status: String?
    var project: String?
    var permalink: URL?
    var notes: String
    var createdBy: String?
    var createdAt: Date?
    var tags: [String]
    var fields: [(name: String, value: String)]
    var subtasks: [AsanaSubtask]
    var comments: [AsanaComment]
    var attachments: [AsanaAttachment]
    var parent: AsanaLink?
    /// «Эту задачу блокируют»: что должно быть сделано до неё.
    var blockedBy: [AsanaLink]
    /// «Эта задача блокирует»: что ждёт её.
    var blocking: [AsanaLink]

    static func == (l: AsanaTaskDetail, r: AsanaTaskDetail) -> Bool {
        l.name == r.name && l.completed == r.completed && l.assignee == r.assignee && l.dueOn == r.dueOn && l.status == r.status
            && l.notes == r.notes && l.createdBy == r.createdBy && l.tags == r.tags && l.subtasks == r.subtasks && l.comments == r.comments
            && l.attachments == r.attachments && l.parent == r.parent && l.blockedBy == r.blockedBy && l.blocking == r.blocking
            && l.fields.map { "\($0.name)=\($0.value)" } == r.fields.map { "\($0.name)=\($0.value)" }
    }
}

struct AsanaSubtask: Identifiable, Equatable {
    let id: String
    let name: String
    let completed: Bool
    let assignee: String?
    let url: URL?
}

struct AsanaComment: Identifiable, Equatable {
    let id: String
    let author: String
    var text: String
    let createdAt: Date?
    /// Файлы, прикреплённые вместе с комментарием: Asana хранит их отдельными записями ленты, мы склеиваем их с комментарием.
    var attachments: [AsanaAttachment] = []

}

enum AsanaError: LocalizedError, Equatable {
    case unauthorized, forbidden, rateLimited, http(Int), network(String), badResponse, noWorkspace

    var errorDescription: String? {
        switch self {
        case .unauthorized: return L("Токен Asana недействителен", "The Asana token is invalid")
        case .forbidden: return L("Нет доступа к этим данным в Asana", "No access to this data in Asana")
        case .rateLimited: return L("Asana просит подождать (лимит запросов)", "Asana asked to wait (rate limit)")
        case .http(let code): return L("Asana ответила кодом \(code)", "Asana answered with code \(code)")
        case .network(let message): return message
        case .badResponse: return L("Непонятный ответ Asana", "Unexpected Asana response")
        case .noWorkspace: return L("В аккаунте Asana нет рабочего пространства", "The Asana account has no workspace")
        }
    }
}
