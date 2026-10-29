import Foundation

/// Lee las sesiones locales de Claude Code (~/.claude/projects/*/*.jsonl) sin modificarlas.
enum ClaudeHistory {
    static var root: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects") }

    /// Texto visible de una línea de usuario/asistente; nil si es ruido (etiquetas de IDE, meta, herramientas).
    static func text(of object: [String: Any]) -> (role: AIMessage.Role, text: String)? {
        guard let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let string = message["content"] as? String { parts = [string] }
        else if let blocks = message["content"] as? [[String: Any]] {
            parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        }
        let text = parts.filter { !$0.hasPrefix("<") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : (type == "user" ? .user : .assistant, text)
    }

    static func summary(of url: URL) -> AIConversationSummary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 96 * 1024)) ?? Data()
        var title: String?, cwd: String?
        for line in head.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            cwd = cwd ?? object["cwd"] as? String
            if title == nil, let (role, text) = text(of: object), role == .user { title = String(text.prefix(80)) }
            if title != nil, cwd != nil { break }
        }
        guard let title else { return nil } // sesiones sin mensajes legibles no se listan
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        return AIConversationSummary(id: url.deletingPathExtension().lastPathComponent, provider: .claude,
            title: title, root: cwd, updatedAt: date, model: nil)
    }

    static func sessions(in root: URL = root) -> [AIConversationSummary] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.flatMap { folder -> [AIConversationSummary] in
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "jsonl" }.compactMap(summary(of:))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func transcript(id: String, in root: URL = root) -> [AIMessage] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        for folder in folders {
            let url = folder.appendingPathComponent("\(id).jsonl")
            guard let data = try? Data(contentsOf: url) else { continue }
            var result: [AIMessage] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let (role, text) = text(of: object) else { continue }
                // Claude escribe un mensaje por bloque: se unen los consecutivos del asistente.
                if role == .assistant, let last = result.last, last.role == .assistant { result[result.count - 1].text += "\n" + text }
                else { result.append(AIMessage(role: role, text: text)) }
            }
            return result.suffix(200).map { $0 }
        }
        return []
    }
}
