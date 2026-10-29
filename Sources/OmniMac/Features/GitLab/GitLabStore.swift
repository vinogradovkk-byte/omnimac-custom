import Foundation
import Security

/// Токен лежит только в связке ключей macOS; адрес сервера — в настройках приложения.
enum GitLabKeychain {
    private static let service = "com.seergiii.omnimac.gitlab"
    private static let account = "read-token"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

final class GitLabStore: ObservableObject {
    enum Phase: Equatable { case needsSetup, loading, loaded, failed(String) }

    @Published private(set) var phase: Phase = .needsSetup
    @Published private(set) var requests: [GitLabMergeRequest] = []
    /// «На ревью»: МР, где меня назначили ревьюером. Непроверенные и с новыми коммитами сверху, проверенные ниже.
    @Published private(set) var reviews: [GitLabMergeRequest] = []
    enum Section: String { case mine, review }
    @Published var section: Section = .mine

    /// Сколько МР на ревью ждут меня (не проверены или обновились после проверки).
    var reviewsWaiting: Int { reviews.filter { !$0.isDoneForMe }.count }
    @Published private(set) var username: String?
    @Published private(set) var updatedAt: Date?
    @Published var hostText: String
    @Published var tokenText = ""

    static let days = 3
    private static let hostKey = "gitlab.host"
    private var credentials: GitLabCredentials?
    private var loadTask: Task<Void, Never>?

    init() {
        hostText = UserDefaults.standard.string(forKey: Self.hostKey) ?? "https://gitlab.com"
        // В связку ключей не лезем при запуске: macOS может спросить пароль, и приложение замерло бы до ответа.
        if Self.mayHaveToken { phase = .loading }
    }

    private static let connectedKey = "gitlab.connected"
    /// Пока признак не записан (первая версия с этой вкладкой), токен мог уже лежать в связке ключей: проверяем её один раз.
    private static var mayHaveToken: Bool { UserDefaults.standard.object(forKey: connectedKey) as? Bool ?? true }
    private var loadingToken = false

    var isConnected: Bool { credentials != nil || Self.mayHaveToken }

    /// Вызывается при открытии вкладки: токен читается с фонового потока, потом идёт обновление.
    func open() {
        if credentials != nil { refresh(); return }
        guard Self.mayHaveToken, !loadingToken else { return }
        loadingToken = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let token = GitLabKeychain.load()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingToken = false
                if let token, let host = GitLabClient.normalizedHost(self.hostText) {
                    self.credentials = GitLabCredentials(host: host, token: token)
                    self.refresh()
                } else {
                    UserDefaults.standard.set(false, forKey: Self.connectedKey)
                    self.phase = .needsSetup
                }
            }
        }
    }
    func requests(_ state: GitLabMergeRequest.State) -> [GitLabMergeRequest] { requests.filter { $0.state == state } }

    /// Вызывается при открытии вкладки: опроса по таймеру нет.
    func refresh() {
        guard let credentials else { phase = .needsSetup; return }
        loadTask?.cancel()
        if requests.isEmpty { phase = .loading }
        loadTask = Task { @MainActor in
            do {
                let client = GitLabClient(credentials: credentials)
                let me = try await client.currentUser()
                async let list = client.myMergeRequests(days: Self.days)
                async let review = client.reviewRequests(me: me)
                let (items, reviewItems) = try await (list, review)
                guard !Task.isCancelled else { return }
                username = me.username; requests = items; reviews = Self.sortedForReview(reviewItems); updatedAt = Date(); phase = .loaded
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Группы по исходной ветке. Порядок групп и МР внутри них сохраняется как в `items`: группа стоит там, где её самый
    /// первый (самый свежий) МР, поэтому свежая работа остаётся наверху.
    static func groupedBySourceBranch(_ items: [GitLabMergeRequest]) -> [GitLabBranchGroup] {
        var order: [String] = []
        var buckets: [String: [GitLabMergeRequest]] = [:]
        for mr in items {
            let branch = mr.sourceBranch.isEmpty ? "—" : mr.sourceBranch
            if buckets[branch] == nil { order.append(branch) }
            buckets[branch, default: []].append(mr)
        }
        return order.map { GitLabBranchGroup(branch: $0, items: buckets[$0] ?? []) }
    }

    /// Ветка «в работе», пока в ней есть хоть один активный МР (`isActive`); только когда все её МР завершены, она уезжает
    /// вниз. Внутри группы активные МР стоят выше завершённых. Порядок групп и МР в каждой «корзине» — как в `items`.
    static func orderedGroups(_ items: [GitLabMergeRequest], isActive: (GitLabMergeRequest) -> Bool) -> (active: [GitLabBranchGroup], finished: [GitLabBranchGroup]) {
        let groups = groupedBySourceBranch(items).map { group in
            GitLabBranchGroup(branch: group.branch, items: group.items.filter(isActive) + group.items.filter { !isActive($0) })
        }
        return (groups.filter { $0.items.contains(where: isActive) }, groups.filter { !$0.items.contains(where: isActive) })
    }

    /// Активные (не смотрел или после проверки пришли коммиты) сверху по свежести, проверенные ниже.
    static func sortedForReview(_ items: [GitLabMergeRequest]) -> [GitLabMergeRequest] {
        func fresh(_ mr: GitLabMergeRequest) -> Date { mr.finishedAt ?? mr.updatedAt }
        return items.filter { !$0.isDoneForMe }.sorted { fresh($0) > fresh($1) } + items.filter { $0.isDoneForMe }.sorted { fresh($0) > fresh($1) }
    }

    /// Проверяет токен и только после успеха сохраняет его.
    func connect() {
        guard let host = GitLabClient.normalizedHost(hostText) else { phase = .failed(GitLabError.invalidHost.localizedDescription); return }
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        phase = .loading
        Task { @MainActor in
            do {
                _ = try await GitLabClient(credentials: GitLabCredentials(host: host, token: token)).currentUser()
                GitLabKeychain.save(token)
                UserDefaults.standard.set(host.absoluteString, forKey: Self.hostKey)
                credentials = GitLabCredentials(host: host, token: token)
                UserDefaults.standard.set(true, forKey: Self.connectedKey)
                tokenText = ""
                refresh()
            } catch { phase = .failed(error.localizedDescription) }
        }
    }

    func disconnect() {
        loadTask?.cancel()
        GitLabKeychain.delete()
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        credentials = nil; requests = []; reviews = []; username = nil; updatedAt = nil; tokenText = ""
        phase = .needsSetup
    }

    func showSetupAgain() { phase = .needsSetup }

    var tokenPageURL: URL? {
        GitLabClient.normalizedHost(hostText).map { $0.appendingPathComponent("-/user_settings/personal_access_tokens") }
    }
}
