import AppKit
import ApplicationServices

enum VSCodeNewWindowInvocation: Equatable {
    case accessibilityPress
    case deferredAccessibilityPress
}

enum VSCodeWindowProvider {
    static let bundleIdentifier = "com.microsoft.VSCode"

    static func isSupported(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == self.bundleIdentifier
    }

    static func shouldShowNotchTab(windowCount _: Int) -> Bool {
        true
    }

    static func isNewWindowCommand(character: String?, modifiers: UInt32) -> Bool {
        character?.lowercased() == "n" && modifiers == 1
    }

    static func newWindowInvocation(isFrontmost: Bool) -> VSCodeNewWindowInvocation {
        isFrontmost ? .deferredAccessibilityPress : .accessibilityPress
    }

    @discardableResult
    static func openNewWindow() -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            isSupported(bundleIdentifier: $0.bundleIdentifier)
        }) else {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else { return false }
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
            return true
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        for item in menuItems(applicationElement) {
            let character = AX.string(item, kAXMenuItemCmdCharAttribute as String)
            let modifiers = (AX.attribute(item, kAXMenuItemCmdModifiersAttribute as String) as? NSNumber)?.uint32Value
            if isNewWindowCommand(character: character, modifiers: modifiers ?? 0) {
                switch newWindowInvocation(isFrontmost: app.isActive) {
                case .accessibilityPress:
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                case .deferredAccessibilityPress:
                    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        AXUIElementPerformAction(item, kAXPressAction as CFString)
                    }
                    return true
                }
            }
        }
        return false
    }

    static func windows() -> [VSCodeWindow] {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: {
                  isSupported(bundleIdentifier: $0.bundleIdentifier)
              }) else { return [] }

        let pid = app.processIdentifier
        let applicationElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)

        struct DiscoveredWindow {
            let id: CGWindowID
            let element: AXUIElement?
            let selectionElement: AXUIElement?
            let rawTitle: String
            let name: VSCodeWindowName
            let isMinimized: Bool
        }

        var seen = Set<CGWindowID>()
        var discovered: [DiscoveredWindow] = AX.elements(applicationElement, kAXWindowsAttribute as String)
            .compactMap { element in
                guard AX.string(element, kAXSubroleAttribute as String) == kAXStandardWindowSubrole as String,
                      let id = AX.windowID(element),
                      seen.insert(id).inserted else { return nil }

                let title = AX.string(element, kAXTitleAttribute as String) ?? ""
                let documentURL = documentURL(from: AX.attribute(element, kAXDocumentAttribute as String))
                return DiscoveredWindow(
                    id: id,
                    element: element,
                    selectionElement: nil,
                    rawTitle: title,
                    name: VSCodeWindowNaming.parse(title: title, documentURL: documentURL),
                    isMinimized: AX.bool(element, kAXMinimizedAttribute as String)
                )
            }

        // Electron can omit windows on other Spaces from AXWindows. VS Code's own
        // Window menu still exposes an exact AX item for each of them. Using that menu
        // avoids requiring the unrelated Screen Recording permission merely to read
        // CoreGraphics window titles.
        let menuEntries = windowMenuEntries(
            applicationElement,
            accessibleTitles: Set(discovered.map(\.rawTitle))
        )
        var fallbackCounts = Dictionary(
            VSCodeWindowDiscovery.fallbackMenuTitles(
                accessibleTitles: discovered.map(\.rawTitle),
                windowMenuTitles: menuEntries.map(\.title)
            ).map { ($0, 1) },
            uniquingKeysWith: +
        )
        var titleOccurrences: [String: Int] = [:]
        for entry in menuEntries where fallbackCounts[entry.title, default: 0] > 0 {
            fallbackCounts[entry.title, default: 0] -= 1
            titleOccurrences[entry.title, default: 0] += 1
            let id = syntheticWindowID(
                title: entry.title,
                occurrence: titleOccurrences[entry.title, default: 1],
                avoiding: &seen
            )
            discovered.append(DiscoveredWindow(
                id: id,
                element: nil,
                selectionElement: entry.element,
                rawTitle: entry.title,
                name: VSCodeWindowNaming.parse(title: entry.title, documentURL: nil),
                isMinimized: false
            ))
        }
        let displayNames = VSCodeWindowNaming.displayNames(
            for: discovered.map(\.name),
            noFolder: L("Без папки", "No folder")
        )

        return zip(discovered, displayNames).map { window, displayName in
            VSCodeWindow(
                id: window.id,
                pid: pid,
                element: window.element,
                selectionElement: window.selectionElement,
                rawTitle: window.rawTitle,
                name: window.name,
                displayName: displayName,
                isMinimized: window.isMinimized
            )
        }
    }

    @discardableResult
    static func focus(_ window: VSCodeWindow) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: window.pid),
              isSupported(bundleIdentifier: app.bundleIdentifier) else { return false }

        if let selectionElement = window.selectionElement {
            let result = AXUIElementPerformAction(selectionElement, kAXPressAction as CFString)
            guard result == .success else { return false }
            _ = app.activate()
            return true
        }

        guard let element = window.element else { return false }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        ) == .success else { return false }

        if AX.bool(element, kAXMinimizedAttribute as String) {
            let result = AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
            guard result == .success else { return false }
        }

        let raiseResult = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        guard raiseResult == .success else { return false }
        _ = AXUIElementSetAttributeValue(
            element,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        return app.activate()
    }

    private struct WindowMenuEntry {
        let title: String
        let element: AXUIElement
    }

    private static func windowMenuEntries(
        _ application: AXUIElement,
        accessibleTitles: Set<String>
    ) -> [WindowMenuEntry] {
        guard let menuBar = AX.element(application, kAXMenuBarAttribute as String) else { return [] }

        // Sin ventanas visibles en este escritorio AXWindows llega vacío y no hay título con el que reconocer
        // el menú Ventana: entonces se identifica por el nombre del menú de la barra.
        let windowMenuNames: Set<String> = ["window", "окно", "ventana"]
        for menuBarItem in AX.elements(menuBar, kAXChildrenAttribute as String) {
            if accessibleTitles.isEmpty,
               !windowMenuNames.contains((AX.string(menuBarItem, kAXTitleAttribute as String) ?? "").lowercased()) { continue }
            for menu in AX.elements(menuBarItem, kAXChildrenAttribute as String) {
                let items = AX.elements(menu, kAXChildrenAttribute as String)
                guard let separator = items.lastIndex(where: {
                    (AX.string($0, kAXTitleAttribute as String) ?? "").isEmpty
                }) else { continue }
                let entries = items[items.index(after: separator)...].compactMap { item -> WindowMenuEntry? in
                    guard AX.string(item, kAXRoleAttribute as String) == kAXMenuItemRole as String,
                          let title = AX.string(item, kAXTitleAttribute as String),
                          !title.isEmpty else { return nil }
                    // «Traer todo al frente» y similares llevan atajo; las ventanas no.
                    if accessibleTitles.isEmpty, !(AX.string(item, kAXMenuItemCmdCharAttribute as String) ?? "").isEmpty { return nil }
                    return WindowMenuEntry(title: title, element: item)
                }
                if accessibleTitles.isEmpty ? !entries.isEmpty : entries.contains(where: { accessibleTitles.contains($0.title) }) {
                    return entries
                }
            }
        }
        return []
    }

    private static func menuItems(_ application: AXUIElement) -> [AXUIElement] {
        guard let menuBar = AX.element(application, kAXMenuBarAttribute as String) else { return [] }
        return AX.elements(menuBar, kAXChildrenAttribute as String).flatMap { menuBarItem in
            AX.elements(menuBarItem, kAXChildrenAttribute as String).flatMap { menu in
                AX.elements(menu, kAXChildrenAttribute as String)
            }
        }
    }

    private static func syntheticWindowID(
        title: String,
        occurrence: Int,
        avoiding seen: inout Set<CGWindowID>
    ) -> CGWindowID {
        var hash: UInt32 = 2_166_136_261
        for byte in title.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        hash = (hash ^ UInt32(occurrence)) &* 16_777_619
        var candidate = hash | 0x8000_0000
        while seen.contains(candidate) { candidate &+= 1 }
        seen.insert(candidate)
        return candidate
    }

    private static func documentURL(from value: CFTypeRef?) -> URL? {
        if let url = value as? URL { return url }
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(fileURLWithPath: raw)
    }
}
