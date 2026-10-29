import XCTest
@testable import OmniMac

final class VSCodeWindowNamingTests: XCTestCase {
    func testParsesRootFromEditorTitle() {
        XCTAssertEqual(
            VSCodeWindowNaming.parse(
                title: "AppDelegate.swift — ominc — Visual Studio Code",
                documentURL: URL(fileURLWithPath: "/Users/dev/project/AppDelegate.swift")
            ),
            VSCodeWindowName(root: "ominc", editor: "AppDelegate.swift", fallback: nil)
        )
    }

    func testParsesCurrentVSCodeTitleWithoutApplicationSuffix() {
        XCTAssertEqual(
            VSCodeWindowNaming.parse(
                title: "Расширение: Codex — ominc",
                documentURL: nil
            ),
            VSCodeWindowName(root: "ominc", editor: "Расширение: Codex", fallback: nil)
        )
    }

    func testPreservesRootCaseAndUnicode() {
        XCTAssertEqual(
            VSCodeWindowNaming.parse(
                title: "Файл.swift — МойПроект — Visual Studio Code",
                documentURL: nil
            ).root,
            "МойПроект"
        )
    }

    func testParsesRootOnlyTitle() {
        XCTAssertEqual(
            VSCodeWindowNaming.parse(title: "ominc — Visual Studio Code", documentURL: nil).root,
            "ominc"
        )
    }

    func testStandaloneFileHasNoRoot() {
        XCTAssertNil(
            VSCodeWindowNaming.parse(
                title: "notes.txt — Visual Studio Code",
                documentURL: URL(fileURLWithPath: "/tmp/notes.txt")
            ).root
        )
    }

    func testEmptyWindowHasNoRoot() {
        XCTAssertEqual(
            VSCodeWindowNaming.parse(title: "Visual Studio Code", documentURL: nil),
            VSCodeWindowName(root: nil, editor: nil, fallback: nil)
        )
    }

    func testCustomTitleFallsBackWithoutDroppingWindow() {
        XCTAssertEqual(
            VSCodeWindowNaming.parse(title: "My custom editor title", documentURL: nil).fallback,
            "My custom editor title"
        )
    }

    func testDuplicateRootsAppendEditorNames() {
        let names = [
            VSCodeWindowName(root: "ominc", editor: "App.swift", fallback: nil),
            VSCodeWindowName(root: "ominc", editor: "Tests.swift", fallback: nil),
        ]

        XCTAssertEqual(
            VSCodeWindowNaming.displayNames(for: names, noFolder: "No folder"),
            ["ominc — App.swift", "ominc — Tests.swift"]
        )
    }

    func testDuplicateNoFolderNamesGetStableSuffixes() {
        let names = [
            VSCodeWindowName(root: nil, editor: "notes.txt", fallback: nil),
            VSCodeWindowName(root: nil, editor: "notes.txt", fallback: nil),
        ]

        XCTAssertEqual(
            VSCodeWindowNaming.displayNames(for: names, noFolder: "No folder"),
            ["No folder — notes.txt", "No folder — notes.txt (2)"]
        )
    }
}

final class VSCodeWindowProviderTests: XCTestCase {
    func testOnlyRegularVSCodeBundleIdentifierIsSupported() {
        XCTAssertTrue(VSCodeWindowProvider.isSupported(bundleIdentifier: "com.microsoft.VSCode"))
        XCTAssertFalse(VSCodeWindowProvider.isSupported(bundleIdentifier: "com.microsoft.VSCodeInsiders"))
        XCTAssertFalse(VSCodeWindowProvider.isSupported(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
        XCTAssertFalse(VSCodeWindowProvider.isSupported(bundleIdentifier: nil))
    }

    func testNotchTabRemainsVisibleWithoutAnOpenWindow() {
        XCTAssertTrue(VSCodeWindowProvider.shouldShowNotchTab(windowCount: 1))
        XCTAssertTrue(VSCodeWindowProvider.shouldShowNotchTab(windowCount: 0))
    }

    func testCrossSpaceWindowIsRecoveredFromWindowMenu() {
        XCTAssertEqual(
            VSCodeWindowDiscovery.fallbackMenuTitles(
                accessibleTitles: ["File.swift — ominc"],
                windowMenuTitles: ["Приветствие — test", "File.swift — ominc"]
            ),
            ["Приветствие — test"]
        )
    }

    func testNewWindowCommandRequiresCommandShiftN() {
        XCTAssertTrue(VSCodeWindowProvider.isNewWindowCommand(character: "n", modifiers: 1))
        XCTAssertTrue(VSCodeWindowProvider.isNewWindowCommand(character: "N", modifiers: 1))
        XCTAssertFalse(VSCodeWindowProvider.isNewWindowCommand(character: "n", modifiers: 0))
        XCTAssertFalse(VSCodeWindowProvider.isNewWindowCommand(character: "n", modifiers: 3))
        XCTAssertFalse(VSCodeWindowProvider.isNewWindowCommand(character: nil, modifiers: 1))
    }

    func testFrontmostVSCodeUsesDeferredAccessibilityPress() {
        XCTAssertEqual(VSCodeWindowProvider.newWindowInvocation(isFrontmost: true), .deferredAccessibilityPress)
    }

    func testBackgroundVSCodeUsesAccessibilityPress() {
        XCTAssertEqual(VSCodeWindowProvider.newWindowInvocation(isFrontmost: false), .accessibilityPress)
    }
}
