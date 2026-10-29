import Foundation

struct GitLabMergeRequest: Identifiable, Equatable {
    enum State: String { case opened, merged, closed }
    let id: Int
    let iid: Int
    let projectID: Int
    let title: String
    let state: State
    let webURL: URL
    /// «группа/проект!123»
    let reference: String
    let author: String
    let isDraft: Bool
    let sourceBranch: String
    let targetBranch: String
    let createdAt: Date
    let updatedAt: Date
    /// Дата, по которой МР попадает в окно «за последние дни»: слияние или закрытие.
    let finishedAt: Date?
    let commentCount: Int
    let hasConflicts: Bool
    let pipelineStatus: String?
    let pipelineURL: URL?
    let upvotes: Int
    let downvotes: Int
    /// Ветки обсуждений (threads): решённые / всего решаемых. nil — ещё не загружено или нет прав.
    var resolvedThreads: Int?
    var totalThreads: Int?
    /// Апрувы: сколько человек одобрили и сколько требуется (nil — правила не заданы или МР не открыт).
    var approvals: Int?
    var approvalsRequired: Int?
    /// Моя проверка (только чтение из GitLab): мой 👍 и мой апрув. Для вкладки «На ревью».
    var myLikeAt: Date?
    /// Мои комментарии в МР и сколько из них в решённых обсуждениях.
    var myComments: Int?
    var myResolvedComments: Int?
    var iApproved = false
    var myApprovalAt: Date?
    /// Дата последнего коммита — загружается только для уже проверенных МР.
    var lastCommitAt: Date?

    /// Репозиторий (проект GitLab) без номера МР: «группа/проект!12» → «группа/проект».
    var projectPath: String {
        if let bang = reference.lastIndex(of: "!") { return String(reference[..<bang]) }
        return reference
    }

    /// Короткое имя репозитория для строки: последний компонент пути.
    var projectName: String { projectPath.split(separator: "/").last.map(String.init) ?? projectPath }

    var isReviewedByMe: Bool { myLikeAt != nil || iApproved }
    /// Когда я последний раз «принял» МР: позже этого момента новые коммиты означают, что нужна повторная проверка.
    var reviewedAt: Date? { [myLikeAt, myApprovalAt].compactMap { $0 }.max() }
    /// Проверил → потом прилетел коммит.
    var needsRecheck: Bool {
        guard isReviewedByMe, let commit = lastCommitAt else { return false }
        guard let reviewed = reviewedAt else { return false }
        return commit > reviewed
    }
    /// Уходит вниз списка: проверен и с тех пор не менялся.
    var isDoneForMe: Bool { state != .opened || (hasLikeAndApproval && !needsRecheck) }

    /// Открытый МР считается проверенным мной, только когда стоят и мой лайк, и мой апрув: одного из двух мало.
    var hasLikeAndApproval: Bool { myLikeAt != nil && iApproved }
}

/// Группа МР с одной исходной веткой (откуда идёт МР): несколько МР одной ветки лежат вместе, даже из разных репозиториев.
struct GitLabBranchGroup: Identifiable, Equatable {
    let branch: String
    let items: [GitLabMergeRequest]
    var id: String { branch }
    var repositories: [String] { Array(Set(items.map(\.projectPath))).sorted() }
}

struct GitLabUser: Equatable { let id: Int; let username: String }

struct GitLabCredentials: Equatable {
    var host: URL
    var token: String
}

enum GitLabError: LocalizedError, Equatable {
    case invalidHost
    case unauthorized
    case forbidden
    case http(Int)
    case network(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .invalidHost: return L("Неверный адрес GitLab", "Invalid GitLab address")
        case .unauthorized: return L("Токен недействителен или истёк", "The token is invalid or expired")
        case .forbidden: return L("У токена нет права read_api", "The token lacks the read_api scope")
        case .http(let code): return L("GitLab ответил кодом \(code)", "GitLab answered with code \(code)")
        case .network(let message): return message
        case .badResponse: return L("Непонятный ответ GitLab", "Unexpected GitLab response")
        }
    }
}
