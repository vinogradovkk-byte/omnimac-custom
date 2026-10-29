import Foundation

enum CodexProtocol {
    static func models(from result: [String: Any]) -> [AIModel] {
        let rows = result["data"] as? [[String: Any]] ?? result["models"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String ?? row["model"] as? String else { return nil }
            let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            return AIModel(id: id, name: row["displayName"] as? String ?? row["name"] as? String ?? id,
                           efforts: efforts, defaultEffort: row["defaultReasoningEffort"] as? String, detail: row["description"] as? String)
        }
    }

    static func conversations(from result: [String: Any]) -> [AIConversationSummary] {
        let rows = result["data"] as? [[String: Any]] ?? result["threads"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let timestamp = row["updatedAt"] as? Double ?? row["createdAt"] as? Double ?? 0
            return AIConversationSummary(id: id, provider: .codex,
                title: [row["name"], row["preview"], row["title"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? L("Чат Codex", "Codex chat"),
                root: row["cwd"] as? String, updatedAt: Date(timeIntervalSince1970: timestamp),
                model: row["model"] as? String)
        }
    }

    static func transcript(from result: [String: Any]) -> [AIMessage] {
        let turns = (result["thread"] as? [String: Any])?["turns"] as? [[String: Any]] ?? []
        return turns.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }.compactMap { item in
            switch item["type"] as? String {
            case "userMessage":
                let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                return text.isEmpty ? nil : AIMessage(role: .user, text: text)
            case "agentMessage":
                return (item["text"] as? String).flatMap { $0.isEmpty ? nil : AIMessage(role: .assistant, text: $0) }
            default: return nil
            }
        }
    }

    /// «primary» y «secondary» traen la duración de su ventana en minutos (300 = 5 h, 10080 = semana).
    static func usageWindows(from limits: [String: Any]) -> [AIUsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let row = limits[key] as? [String: Any],
                  let used = (row["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (row["windowDurationMins"] as? NSNumber)?.intValue ?? 0
            let title = minutes >= 7 * 24 * 60 ? L("Неделя", "Week") : minutes > 0 ? L("Сессия · \(minutes / 60) ч", "Session · \(minutes / 60) h") : key
            return AIUsageWindow(title: title, remainingPercent: max(0, 100 - used),
                resetsAt: (row["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
    }
}
