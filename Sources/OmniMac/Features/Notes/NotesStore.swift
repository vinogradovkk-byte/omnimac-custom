import Foundation

/// Заметка OmniMac. Как в «Заметках» macOS: первая строка текста — заголовок, остальное — содержимое.
struct OmniNote: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    var modifiedAt: Date
    var pinned: Bool
    /// Дата удаления: заметка лежит в «Недавно удалённых» 30 дней и только потом пропадает.
    var deletedAt: Date?

    init(id: UUID = UUID(), text: String = "", createdAt: Date = Date(), modifiedAt: Date = Date(), pinned: Bool = false, deletedAt: Date? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.pinned = pinned; self.deletedAt = deletedAt
    }

    var title: String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// Первая непустая строка после заголовка — превью в списке.
    var preview: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Хранилище заметок: один JSON-файл в Application Support, запись атомарная и с задержкой, чтобы набор текста не бил по диску.
final class NotesStore: ObservableObject {
    enum Folder: Equatable { case all, trash }

    @Published private(set) var notes: [OmniNote] = []
    @Published var selectedID: UUID?
    @Published var folder: Folder = .all
    @Published var query = ""

    static let trashDays = 30
    private let fileURL: URL
    private var saveWork: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.seergiii.omnimac.notes", qos: .utility)

    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("OmniMac", isDirectory: true).appendingPathComponent("notes.json")
    }

    init(fileURL: URL = NotesStore.defaultURL, now: Date = Date()) {
        self.fileURL = fileURL
        load(now: now)
        selectedID = visibleNotes.first?.id
    }

    // MARK: - Выборка

    /// Заметки текущей папки: закреплённые сверху, дальше по дате изменения; поиск ищет по всему тексту.
    var visibleNotes: [OmniNote] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return notes
            .filter { folder == .trash ? $0.deletedAt != nil : $0.deletedAt == nil }
            .filter { needle.isEmpty || $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            .sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned { return lhs.pinned }
                return lhs.modifiedAt > rhs.modifiedAt
            }
    }

    var trashCount: Int { notes.filter { $0.deletedAt != nil }.count }
    var activeCount: Int { notes.filter { $0.deletedAt == nil }.count }
    var selected: OmniNote? { notes.first { $0.id == selectedID } }

    // MARK: - Действия

    @discardableResult
    func create() -> OmniNote {
        let note = OmniNote()
        notes.append(note)
        folder = .all; query = ""; selectedID = note.id
        scheduleSave()
        return note
    }

    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].modifiedAt = Date()
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        scheduleSave()
    }

    /// Обычное удаление переносит заметку в «Недавно удалённые»; пустую, которую только что создали, убираем сразу.
    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if notes[index].isEmpty { notes.remove(at: index) }
        else { notes[index].deletedAt = Date(); notes[index].pinned = false }
        if selectedID == id { selectedID = visibleNotes.first?.id }
        scheduleSave()
    }

    func restore(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].deletedAt = nil; notes[index].modifiedAt = Date()
        if selectedID == id { selectedID = visibleNotes.first?.id }
        scheduleSave()
    }

    func deleteForever(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = visibleNotes.first?.id }
        scheduleSave()
    }

    func emptyTrash() {
        notes.removeAll { $0.deletedAt != nil }
        if selected == nil { selectedID = visibleNotes.first?.id }
        scheduleSave()
    }

    func select(_ folder: Folder) {
        self.folder = folder
        if selected.map({ folder == .trash ? $0.deletedAt == nil : $0.deletedAt != nil }) ?? true { selectedID = visibleNotes.first?.id }
    }

    /// Пустую заметку, которую открыли и не заполнили, не копим.
    func discardEmptySelection() {
        if let note = selected, note.isEmpty, note.deletedAt == nil { delete(note.id) }
    }

    // MARK: - Диск

    private func load(now: Date) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let decoded = try? Self.decoder.decode([OmniNote].self, from: data) else {
            // Файл повреждён: оставляем его рядом под другим именем, а не затираем.
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.deletingLastPathComponent().appendingPathComponent("notes.corrupt-\(Int(now.timeIntervalSince1970)).json"))
            return
        }
        let limit = now.addingTimeInterval(-Double(Self.trashDays) * 86_400)
        notes = decoded.filter { ($0.deletedAt ?? now) >= limit }
        if notes.count != decoded.count { scheduleSave() }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Вызывается и при закрытии приложения, чтобы не потерять последние секунды набора.
    func saveNow() {
        saveWork?.cancel(); saveWork = nil
        let snapshot = notes, url = fileURL
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch { NSLog("OmniMac notes: не удалось сохранить: \(error.localizedDescription)") }
        }
    }
}
