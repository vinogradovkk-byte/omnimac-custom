import Foundation

enum AIProviderKind: String, Codable, CaseIterable, Identifiable {
    case codex
    case claude
    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

struct AIModel: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    /// Niveles de razonamiento que admite el modelo, de menor a mayor (los anuncia el propio cliente).
    var efforts: [String] = []
    var defaultEffort: String?
    var detail: String?

    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "low": return L("Низкий", "Low")
        case "medium": return L("Средний", "Medium")
        case "high": return L("Высокий", "High")
        case "xhigh": return L("Очень высокий", "Extra high")
        case "max": return L("Максимум", "Max")
        case "ultra": return "Ultra"
        default: return effort.capitalized
        }
    }
}

/// Una ventana de límite del cliente (5 h, semana…): lo que queda y cuándo se renueva.
struct AIUsageWindow: Equatable {
    var title: String
    var remainingPercent: Double
    var resetsAt: Date?
}

struct AIUsage: Equatable {
    var windows: [AIUsageWindow] = []
    var remainingPercent: Double?
    var resetsAt: Date?
    var inputTokens: Int?
    var outputTokens: Int?
    var updatedAt = Date()
}

struct AIConversationSummary: Identifiable, Codable, Equatable {
    let id: String
    let provider: AIProviderKind
    var title: String
    var root: String?
    var updatedAt: Date
    var model: String?
}

struct AIMessage: Identifiable, Equatable {
    enum Role { case user, assistant, system }
    let id: UUID
    let role: Role
    var text: String
    var images: [URL]

    init(id: UUID = UUID(), role: Role, text: String, images: [URL] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
    }
}

enum AIChatError: LocalizedError, Equatable {
    case clientMissing(String)
    case signedOut
    case protocolFailure(String)
    case processExited(Int32)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .clientMissing(let name): return "\(name) is not installed"
        case .signedOut: return "Sign in is required"
        case .protocolFailure(let message): return message
        case .processExited(let code): return "Provider exited with code \(code)"
        case .cancelled: return "Cancelled"
        }
    }
}
