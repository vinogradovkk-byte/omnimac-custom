import SwiftUI

/// Заметки внутри OmniMac по образцу «Заметок» macOS: слева список с поиском, справа текст; первая строка — заголовок.
struct NotesTab: View {
    @ObservedObject var store: NotesStore
    @State private var editorText = ""
    @State private var loadedID: UUID?
    @FocusState private var editorFocused: Bool

    private let gold = Color(red: 0.99, green: 0.80, blue: 0.20)
    private let field = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let line = Color(red: 0.19, green: 0.20, blue: 0.24)

    var body: some View {
        HStack(spacing: 10) {
            sidebar.frame(width: 230)
            editor
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 6)
        .onAppear { syncEditor() }
        .onChange(of: store.selectedID) { _ in syncEditor() }
        .onChange(of: editorText) { value in
            if let id = loadedID, store.selectedID == id { store.update(id, text: value) }
        }
    }

    // MARK: - Список

    private var sidebar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                TextField(L("Поиск", "Search"), text: $store.query).textFieldStyle(.plain).font(.system(size: 12))
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))

            HStack(spacing: 6) {
                folderButton(L("Заметки", "Notes"), symbol: "note.text", count: store.activeCount, folder: .all)
                folderButton(L("Удалённые", "Deleted"), symbol: "trash", count: store.trashCount, folder: .trash)
                Spacer(minLength: 0)
                Button { store.discardEmptySelection(); store.create(); DispatchQueue.main.async { editorFocused = true } } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13)).foregroundStyle(gold).frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
                }.buttonStyle(.plain).help(L("Новая заметка", "New note"))
            }

            let notes = store.visibleNotes
            if notes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: store.folder == .trash ? "trash" : "note.text").font(.system(size: 20)).foregroundStyle(.white.opacity(0.25))
                    Text(emptyText).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(notes) { row($0) } }
                }
            }
        }
    }

    private var emptyText: String {
        if !store.query.isEmpty { return L("Ничего не найдено", "Nothing found") }
        return store.folder == .trash ? L("Нет удалённых заметок", "No deleted notes") : L("Нет заметок", "No notes")
    }

    private func folderButton(_ title: String, symbol: String, count: Int, folder: NotesStore.Folder) -> some View {
        let on = store.folder == folder
        return Button { store.discardEmptySelection(); store.select(folder) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5))
                Text(title).font(.system(size: 11, weight: .medium))
                Text("\(count)").font(.system(size: 9.5, weight: .bold)).opacity(0.55)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .foregroundStyle(on ? Color.white : Color.white.opacity(0.5))
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.white.opacity(0.14) : .clear))
        }.buttonStyle(.plain)
    }

    private func row(_ note: OmniNote) -> some View {
        let selected = store.selectedID == note.id
        return Button { store.discardEmptySelection(); store.selectedID = note.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(gold) }
                    Text(note.title.isEmpty ? L("Новая заметка", "New note") : note.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(dateText(note.modifiedAt)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
                    Text(note.preview.isEmpty ? L("Нет дополнительного текста", "No additional text") : note.preview)
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? gold.opacity(0.22) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if note.deletedAt == nil {
                Button(note.pinned ? L("Открепить", "Unpin") : L("Закрепить", "Pin")) { store.togglePin(note.id) }
                Button(L("Удалить", "Delete"), role: .destructive) { store.delete(note.id) }
            } else {
                Button(L("Восстановить", "Restore")) { store.restore(note.id) }
                Button(L("Удалить навсегда", "Delete permanently"), role: .destructive) { store.deleteForever(note.id) }
            }
        }
    }

    /// «14:05» сегодня, «Вчера», иначе число.
    private func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return L("Вчера", "Yesterday") }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - Редактор

    @ViewBuilder private var editor: some View {
        if let note = store.selected {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(L("Изменено ", "Edited ") + note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    Spacer()
                    if note.deletedAt == nil {
                        toolButton(note.pinned ? "pin.slash" : "pin", help: note.pinned ? L("Открепить", "Unpin") : L("Закрепить", "Pin")) { store.togglePin(note.id) }
                        toolButton("trash", help: L("Удалить", "Delete")) { store.delete(note.id) }
                    } else {
                        Button { store.restore(note.id) } label: { Text(L("Восстановить", "Restore")).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8).fill(gold.opacity(0.3))) }.buttonStyle(.plain)
                        toolButton("trash.slash", help: L("Удалить навсегда", "Delete permanently")) { store.deleteForever(note.id) }
                    }
                }
                TextEditor(text: $editorText)
                    .font(.system(size: 13)).scrollContentBackground(.hidden).focused($editorFocused)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(field).overlay(RoundedRectangle(cornerRadius: 12).stroke(line)))
                    .disabled(note.deletedAt != nil)
                    .overlay(alignment: .topLeading) {
                        if editorText.isEmpty && note.deletedAt == nil {
                            Text(L("Название\nТекст заметки", "Title\nNote text")).font(.system(size: 13)).foregroundStyle(.white.opacity(0.25)).padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "note.text").font(.system(size: 28)).foregroundStyle(.white.opacity(0.2))
                Text(L("Выберите заметку или создайте новую", "Select a note or create a new one")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
        }.buttonStyle(.plain).help(help)
    }

    /// Подставляет текст выбранной заметки в редактор, не отправляя его обратно в хранилище как «правку».
    private func syncEditor() {
        loadedID = nil
        editorText = store.selected?.text ?? ""
        loadedID = store.selectedID
    }
}
