import AppKit
import XCTest
@testable import OmniMac

final class EditingShortcutsTests: XCTestCase {
    func testCommandLetterShortcutsAreRecognizedByKeyCode() {
        XCTAssertEqual(EditingShortcuts.action(keyCode: 9, modifiers: [.command]), .paste)      // V, también con teclado ruso
        XCTAssertEqual(EditingShortcuts.action(keyCode: 8, modifiers: [.command]), .copy)
        XCTAssertEqual(EditingShortcuts.action(keyCode: 7, modifiers: [.command]), .cut)
        XCTAssertEqual(EditingShortcuts.action(keyCode: 0, modifiers: [.command]), .selectAll)
        XCTAssertEqual(EditingShortcuts.action(keyCode: 6, modifiers: [.command]), .undo)
        XCTAssertEqual(EditingShortcuts.action(keyCode: 6, modifiers: [.command, .shift]), .redo)
    }

    func testIgnoresCapsLockAndOtherModifiers() {
        XCTAssertEqual(EditingShortcuts.action(keyCode: 9, modifiers: [.command, .capsLock]), .paste)
        XCTAssertNil(EditingShortcuts.action(keyCode: 9, modifiers: [.command, .option]))
        XCTAssertNil(EditingShortcuts.action(keyCode: 9, modifiers: [.control]))
        XCTAssertNil(EditingShortcuts.action(keyCode: 9, modifiers: []))
        XCTAssertNil(EditingShortcuts.action(keyCode: 9, modifiers: [.command, .shift]))
    }
}
