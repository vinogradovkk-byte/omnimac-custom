import AppKit
import ApplicationServices

struct VSCodeWindowName: Equatable {
    let root: String?
    let editor: String?
    let fallback: String?
}

enum VSCodeWindowDiscovery {
    static func fallbackMenuTitles(
        accessibleTitles: [String],
        windowMenuTitles: [String]
    ) -> [String] {
        var remainingAccessible = Dictionary(
            accessibleTitles.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return windowMenuTitles.filter { title in
            guard remainingAccessible[title, default: 0] > 0 else { return true }
            remainingAccessible[title, default: 0] -= 1
            return false
        }
    }
}

enum VSCodeWindowNaming {
    private static let applicationName = "Visual Studio Code"
    private static let separators = [" — ", " - "]

    static func parse(title: String, documentURL: URL?) -> VSCodeWindowName {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else {
            return VSCodeWindowName(root: nil, editor: nil, fallback: nil)
        }
        if cleanedTitle == applicationName {
            return VSCodeWindowName(root: nil, editor: nil, fallback: nil)
        }

        guard let separator = separators.first(where: { cleanedTitle.contains($0) }) else {
            return VSCodeWindowName(root: nil, editor: nil, fallback: cleanedTitle)
        }

        var components = cleanedTitle
            .components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasApplicationSuffix = components.last == applicationName
        if hasApplicationSuffix {
            components.removeLast()
        }

        guard !components.isEmpty else {
            return VSCodeWindowName(root: nil, editor: nil, fallback: nil)
        }
        if components.count >= 2 {
            return VSCodeWindowName(
                root: components.last,
                editor: components.dropLast().joined(separator: separator),
                fallback: nil
            )
        }

        let component = components[0]
        guard hasApplicationSuffix else {
            return VSCodeWindowName(root: nil, editor: nil, fallback: cleanedTitle)
        }
        if documentURL?.lastPathComponent == component {
            return VSCodeWindowName(root: nil, editor: component, fallback: nil)
        }
        return VSCodeWindowName(root: component, editor: nil, fallback: nil)
    }

    static func displayNames(for names: [VSCodeWindowName], noFolder: String) -> [String] {
        let bases = names.map { name in
            nonempty(name.root) ?? nonempty(name.fallback) ?? noFolder
        }
        let counts = Dictionary(bases.map { ($0, 1) }, uniquingKeysWith: +)
        var used: [String: Int] = [:]

        return zip(names, bases).map { name, base in
            var candidate = base
            if counts[base, default: 0] > 1, let editor = nonempty(name.editor) {
                candidate += " — \(editor)"
            }
            used[candidate, default: 0] += 1
            let occurrence = used[candidate, default: 1]
            return occurrence == 1 ? candidate : "\(candidate) (\(occurrence))"
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

final class VSCodeWindow: NSObject, Identifiable {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement?
    let selectionElement: AXUIElement?
    let rawTitle: String
    let name: VSCodeWindowName
    let displayName: String
    let isMinimized: Bool

    init(id: CGWindowID, pid: pid_t, element: AXUIElement?, selectionElement: AXUIElement?, rawTitle: String,
         name: VSCodeWindowName, displayName: String, isMinimized: Bool) {
        self.id = id
        self.pid = pid
        self.element = element
        self.selectionElement = selectionElement
        self.rawTitle = rawTitle
        self.name = name
        self.displayName = displayName
        self.isMinimized = isMinimized
    }
}
