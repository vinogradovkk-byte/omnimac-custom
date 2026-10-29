import Foundation

enum AIProviderState: Equatable {
    case unavailable(String)
    case signedOut
    case ready
    case failed(String)
}

protocol AIProvider: AnyObject {
    var kind: AIProviderKind { get }
    var state: AIProviderState { get }
    var models: [AIModel] { get }
    var conversations: [AIConversationSummary] { get }
    var usage: AIUsage? { get }
    var onEvent: ((AIProviderEvent) -> Void)? { get set }
    func refresh()
    func signIn()
    func startConversation(model: String?, effort: String?, prompt: String, imageURLs: [URL])
    func resume(id: String, model: String?, effort: String?, prompt: String, imageURLs: [URL])
    func loadTranscript(id: String)
    func refreshUsage()
    func cancel()
    func shutdown()
}

enum AIProviderEvent {
    case state(AIProviderState)
    case models([AIModel])
    case conversations([AIConversationSummary])
    case conversationSelected(String)
    case messageStarted(UUID)
    case messageDelta(UUID, String)
    case messageCompleted(UUID, String?)
    case usage(AIUsage?)
    case transcript([AIMessage])
    case failed(String)
}
