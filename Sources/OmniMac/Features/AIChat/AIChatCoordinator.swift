import AppKit
import Combine

final class AIChatCoordinator: ObservableObject {
    @Published var selectedProvider: AIProviderKind = .codex { didSet { syncProvider() } }
    @Published var states: [AIProviderKind: AIProviderState] = [:]
    @Published var models: [AIProviderKind: [AIModel]] = [:]
    @Published var selectedModels: [AIProviderKind: String] = [:]
    @Published var selectedEfforts: [AIProviderKind: String] = [:]
    @Published var messages: [AIProviderKind: [AIMessage]] = [:]
    @Published var conversations: [AIProviderKind: [AIConversationSummary]] = [:]
    @Published var usages: [AIProviderKind: AIUsage] = [:]
    @Published var draft = ""
    @Published var isStreaming = false
    /// Capturas pendientes de enviar (máximo `maxAttachments`) y todas las ya enviadas, que siguen en disco hasta cerrar
    /// para poder abrirlas desde el mensaje.
    @Published var attachments: [URL] = []
    private var sentImages: [URL] = []
    static let maxAttachments = 10
    private static let screenshotsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("omnimac-ai-screens")
    @Published var errorText: String?

    private let providers: [AIProviderKind: AIProvider]
    private var activeConversation: [AIProviderKind: String] = [:]

    init() {
        try? FileManager.default.removeItem(at: Self.screenshotsDirectory)
        providers = [.codex: CodexProvider(), .claude: ClaudeProvider()]
        for (kind, provider) in providers {
            provider.onEvent = { [weak self] event in DispatchQueue.main.async { self?.receive(event, from: kind) } }
        }
    }

    /// Con datos de muestra (capturas de la documentación) no se arranca ningún cliente real.
    var isSample = false

    func start() { if !isSample { providers.values.forEach { $0.refresh() } } }
    func stop() { providers.values.forEach { $0.shutdown() }; clearAllScreenshots() }
    func signIn() { providers[selectedProvider]?.signIn() }
    func refresh() { if !isSample { providers[selectedProvider]?.refresh() } }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, states[selectedProvider] == .ready else { return }
        messages[selectedProvider, default: []].append(AIMessage(role: .user, text: text, images: attachments))
        let model = selectedModels[selectedProvider]
        let effort = effortSteps.isEmpty ? nil : effort(for: selectedProvider)
        if let id = activeConversation[selectedProvider] {
            providers[selectedProvider]?.resume(id: id, model: model, effort: effort, prompt: text, imageURLs: attachments)
        } else {
            providers[selectedProvider]?.startConversation(model: model, effort: effort, prompt: text, imageURLs: attachments)
        }
        sentImages += attachments; attachments = []
        draft = ""; isStreaming = true
    }

    func cancel() { providers[selectedProvider]?.cancel(); isStreaming = false }
    func resume(_ conversation: AIConversationSummary) {
        activeConversation[conversation.provider] = conversation.id
        messages[conversation.provider] = []
        selectedProvider = conversation.provider
        providers[conversation.provider]?.loadTranscript(id: conversation.id)
    }

    /// Modelo elegido (o el primero del cliente) y sus niveles de razonamiento.
    var currentModel: AIModel? {
        let list = models[selectedProvider] ?? []
        return list.first { $0.id == selectedModels[selectedProvider] } ?? list.first
    }
    var effortSteps: [String] { currentModel?.efforts ?? [] }

    /// El nivel elegido si el modelo lo admite; si no, el que el cliente marca por defecto.
    func effort(for kind: AIProviderKind) -> String? {
        let steps = effortSteps
        if let chosen = selectedEfforts[kind], steps.contains(chosen) { return chosen }
        return currentModel?.defaultEffort.flatMap { steps.contains($0) ? $0 : nil } ?? steps.first
    }

    func refreshUsage() { if !isSample { providers[selectedProvider]?.refreshUsage() } }

    func newChat() { activeConversation[selectedProvider] = nil; messages[selectedProvider] = [] }

    func captureScreen() {
        guard Permissions.hasScreenRecording else { Permissions.requestScreenRecording(); Permissions.openScreenRecordingSettings(); return }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        guard attachments.count < Self.maxAttachments else {
            errorText = L("Максимум \(Self.maxAttachments) снимков", "At most \(Self.maxAttachments) screenshots"); return
        }
        Task {
            do {
                let image = try await ScreenGrab.image(of: screen.frame, on: screen, excludingOwnWindows: true)
                try FileManager.default.createDirectory(at: Self.screenshotsDirectory, withIntermediateDirectories: true)
                let url = Self.screenshotsDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
                let bitmap = NSBitmapImageRep(cgImage: Self.downscaled(image, longSide: 1920))
                guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else { return }
                try data.write(to: url, options: .atomic); attachments.append(url)
            } catch { errorText = error.localizedDescription }
        }
    }

    /// Retina da capturas de varios MB; el modelo las reduce igualmente. Nunca se agranda.
    private static func downscaled(_ image: CGImage, longSide: CGFloat) -> CGImage {
        let scale = min(1, longSide / CGFloat(max(image.width, image.height)))
        guard scale < 1, let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        return context.makeImage() ?? image
    }

    func removeAttachment(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        attachments.removeAll { $0 == url }
    }

    private func clearAllScreenshots() {
        try? FileManager.default.removeItem(at: Self.screenshotsDirectory)
        attachments = []; sentImages = []
    }

    private func syncProvider() { if !isSample { providers[selectedProvider]?.refresh() } }
    private func receive(_ event: AIProviderEvent, from kind: AIProviderKind) {
        switch event {
        case .state(let value): states[kind] = value
        case .models(let value): models[kind] = value; if selectedModels[kind] == nil { selectedModels[kind] = value.first?.id }
        case .conversations(let value): conversations[kind] = value
        case .conversationSelected(let id): activeConversation[kind] = id
        case .messageStarted(let id): messages[kind, default: []].append(AIMessage(id: id, role: .assistant, text: ""))
        case .messageDelta(let id, let delta): if let index = messages[kind]?.firstIndex(where: { $0.id == id }) { messages[kind]?[index].text += delta }
        case .messageCompleted: isStreaming = false
        case .usage(let value): usages[kind] = value
        case .transcript(let value): messages[kind] = value
        case .failed(let value): errorText = value; isStreaming = false
        }
    }
}
