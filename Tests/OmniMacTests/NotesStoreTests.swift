import XCTest
@testable import OmniMac

final class NotesStoreTests: XCTestCase {
    private func makeStore(now: Date = Date()) -> (NotesStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omni-notes-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("notes.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (NotesStore(fileURL: url, now: now), url)
    }

    func testTitleIsFirstLineAndPreviewIsTheNext() {
        let note = OmniNote(text: "\nПокупки\nмолоко, хлеб\nещё")
        XCTAssertEqual(note.title, "Покупки"); XCTAssertEqual(note.preview, "молоко, хлеб")
    }

    func testPinnedFirstThenNewestAndSearchIgnoresCase() {
        let (store, _) = makeStore()
        let a = store.create(); store.update(a.id, text: "Покупки\nхлеб")
        let b = store.create(); store.update(b.id, text: "Идея")
        XCTAssertEqual(store.visibleNotes.first?.id, b.id)
        store.togglePin(a.id); XCTAssertEqual(store.visibleNotes.first?.id, a.id)
        store.query = "ХЛЕБ"; XCTAssertEqual(store.visibleNotes.map(\.id), [a.id])
    }

    func testDeleteGoesToTrashRestoresAndEmptyNotesVanish() {
        let (store, _) = makeStore()
        let a = store.create(); store.update(a.id, text: "x")
        store.delete(a.id); XCTAssertEqual(store.trashCount, 1)
        store.restore(a.id); XCTAssertEqual(store.trashCount, 0)
        let empty = store.create(); store.delete(empty.id)
        XCTAssertFalse(store.notes.contains { $0.id == empty.id })
    }

    func testPersistsAcrossRelaunchAndTrashExpires() {
        let (store, url) = makeStore()
        let a = store.create(); store.update(a.id, text: "Привет"); store.saveNow()
        XCTAssertEqual(NotesStore(fileURL: url).activeCount, 1)
        store.delete(a.id); store.saveNow()
        XCTAssertEqual(NotesStore(fileURL: url, now: Date().addingTimeInterval(31 * 86_400)).trashCount, 0)
    }
}
