import Foundation
import Security

enum AsanaKeychain {
    private static let service = "com.seergiii.omnimac.asana"
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

final class AsanaStore: ObservableObject {
    enum Phase: Equatable { case needsSetup, loading, loaded, failed(String) }
    enum DetailState { case loading, loaded(AsanaTaskDetail), failed(String) }

    @Published private(set) var phase: Phase = .needsSetup
    @Published private(set) var tasks: [AsanaTask] = []
    @Published private(set) var statusOrder: [String] = []
    @Published private(set) var doneToday = 0
    @Published private(set) var userName: String?
    @Published private(set) var updatedAt: Date?
    @Published var tokenText = ""
    @Published private(set) var details: [String: DetailState] = [:]
    @Published var expanded: Set<String> = []
    /// Страница задачи внутри OmniMac: стек переходов (подзадача, родитель, зависимость). Пусто — виден список.
    @Published private(set) var path: [AsanaLink] = []
    var current: AsanaLink? { path.last }

    func open(_ link: AsanaLink) {
        path.append(link); loadDetail(link.id, force: true)
    }

    func open(_ task: AsanaTask) { open(AsanaLink(id: task.id, name: task.name, url: task.permalink, completed: false)) }
    func open(_ sub: AsanaSubtask) { open(AsanaLink(id: sub.id, name: sub.name, url: sub.url, completed: sub.completed)) }
    func back() { if !path.isEmpty { path.removeLast() } }
    func backToList() { path = [] }
    /// Скрытые статусы (фильтр). По умолчанию скрыто всё, что не требует действий от меня сейчас, не скрывается ничего.
    @Published var hiddenStatuses: Set<String> { didSet { UserDefaults.standard.set(Array(hiddenStatuses), forKey: Self.hiddenKey) } }

    private static let connectedKey = "asana.connected"
    private static let hiddenKey = "asana.hiddenStatuses"
    private var token: String?
    private var loadTask: Task<Void, Never>?
    private var loadingToken = false

    init() {
        hiddenStatuses = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        if Self.mayHaveToken { phase = .loading }
    }

    private static var mayHaveToken: Bool { UserDefaults.standard.object(forKey: connectedKey) as? Bool ?? false }
    var isConnected: Bool { token != nil || Self.mayHaveToken }

    /// Статусы по порядку колонок доски; незнакомые идут после, «без статуса» в конце.
    var statuses: [String] {
        let present = Set(tasks.map(\.status))
        return Self.orderedStatuses(present: present, order: statusOrder)
    }

    static func orderedStatuses(present: Set<String>, order: [String]) -> [String] {
        let known = order.filter(present.contains)
        let extra = present.subtracting(known).subtracting([AsanaClient.noStatus]).sorted()
        return known + extra + (present.contains(AsanaClient.noStatus) ? [AsanaClient.noStatus] : [])
    }

    func count(for status: String) -> Int { tasks.filter { $0.status == status }.count }
    func tasks(in status: String) -> [AsanaTask] { tasks.filter { $0.status == status } }
    var visibleStatuses: [String] { statuses.filter { !hiddenStatuses.contains($0) } }

    func toggle(_ status: String) {
        if hiddenStatuses.contains(status) { hiddenStatuses.remove(status) } else { hiddenStatuses.insert(status) }
    }

    func open() {
        if token != nil { refresh(); return }
        guard Self.mayHaveToken, !loadingToken else { return }
        loadingToken = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let saved = AsanaKeychain.load()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingToken = false
                if let saved { self.token = saved; self.refresh() }
                else { UserDefaults.standard.set(false, forKey: Self.connectedKey); self.phase = .needsSetup }
            }
        }
    }

    func refresh() {
        guard let token else { phase = .needsSetup; return }
        loadTask?.cancel()
        if tasks.isEmpty { phase = .loading }
        loadTask = Task { @MainActor in
            do {
                let client = AsanaClient(token: token)
                async let me = client.me()
                async let result = client.myTasks()
                let (user, loaded) = try await (me, result)
                guard !Task.isCancelled else { return }
                userName = user.name; tasks = loaded.tasks; doneToday = loaded.doneToday; statusOrder = loaded.sectionOrder; updatedAt = Date(); phase = .loaded
                details = details.filter { key, _ in loaded.tasks.contains { $0.id == key } }
                // Раскрытые строки обновляем, чтобы новые комментарии были видны.
                for id in expanded where loaded.tasks.contains(where: { $0.id == id }) { loadDetail(id, force: true) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func connect() {
        let value = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        phase = .loading
        Task { @MainActor in
            do {
                _ = try await AsanaClient(token: value).me()
                AsanaKeychain.save(value)
                UserDefaults.standard.set(true, forKey: Self.connectedKey)
                token = value; tokenText = ""
                refresh()
            } catch { phase = .failed(error.localizedDescription) }
        }
    }

    func disconnect() {
        loadTask?.cancel()
        AsanaKeychain.delete()
        UserDefaults.standard.set(false, forKey: Self.connectedKey)
        token = nil; tasks = []; details = [:]; expanded = []; path = []; userName = nil; updatedAt = nil; tokenText = ""
        phase = .needsSetup
    }

    func showSetupAgain() { phase = .needsSetup }

    func toggleExpanded(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id); loadDetail(id) }
    }

    func loadDetail(_ id: String, force: Bool = false) {
        guard let token else { return }
        if !force, case .loaded = details[id] ?? .loading { return }
        if details[id] == nil { details[id] = .loading }
        Task { @MainActor in
            do { details[id] = .loaded(try await AsanaClient(token: token).detail(of: id)) }
            catch { details[id] = .failed(error.localizedDescription) }
        }
    }

    /// «2026-10-27» → дата; для подсветки просроченных.
    static func dueDate(_ text: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f.date(from: text)
    }

    static func dueText(_ text: String) -> String {
        dueDate(text).map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? text
    }

    /// Состояние отправки комментария по задачам: nil — не отправляется.
    @Published private(set) var sending: Set<String> = []
    @Published var commentError: [String: String] = [:]

    /// Отправляет комментарий и/или файлы: сначала текст, потом вложения по одному. Результат сразу виден в списке
    /// без повторной загрузки. `completion(true)` — всё ушло; при ошибке поле остаётся как есть, чтобы можно было повторить.
    func send(taskID: String, text: String, files: [URL], completion: @escaping (_ failedFiles: [URL]?) -> Void) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !(value.isEmpty && files.isEmpty), !sending.contains(taskID) else { completion(nil); return }
        sending.insert(taskID); commentError[taskID] = nil
        Task { @MainActor in
            let client = AsanaClient(token: token)
            var failed: [URL] = []
            var firstError: String?
            var postedCommentID: String?
            if !value.isEmpty {
                do {
                    let comment = try await client.postComment(taskGID: taskID, text: value)
                    postedCommentID = comment.id
                    if case .loaded(var detail)? = details[taskID] { detail.comments.append(comment); details[taskID] = .loaded(detail) }
                } catch {
                    commentError[taskID] = error.localizedDescription
                    sending.remove(taskID); completion(nil); return   // текст не ушёл: файлы не трогаем, всё можно повторить
                }
            }
            for url in files {
                do {
                    let attachment = try await client.uploadAttachment(taskGID: taskID, fileURL: url)
                    if case .loaded(var detail)? = details[taskID] {
                        detail.attachments.append(attachment)
                        // Файл виден и в самом комментарии, как в Asana: к только что отправленному, а без текста — отдельной записью.
                        if let id = postedCommentID, let index = detail.comments.firstIndex(where: { $0.id == id }) { detail.comments[index].attachments.append(attachment) }
                        else if let last = detail.comments.last, last.text.isEmpty, last.id.hasPrefix("local-") { detail.comments[detail.comments.count - 1].attachments.append(attachment) }
                        else { detail.comments.append(AsanaComment(id: "local-\(attachment.id)", author: userName ?? "—", text: "", createdAt: Date(), attachments: [attachment])) }
                        details[taskID] = .loaded(detail)
                    }
                } catch {
                    failed.append(url)
                    if firstError == nil { firstError = "\(url.lastPathComponent): \(error.localizedDescription)" }
                }
            }
            if let firstError { commentError[taskID] = firstError }
            sending.remove(taskID); completion(failed)
        }
    }

    static let tokenPageURL = URL(string: "https://app.asana.com/0/my-apps")!
}
