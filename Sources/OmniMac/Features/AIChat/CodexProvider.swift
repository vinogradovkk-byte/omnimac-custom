import AppKit
import Foundation

final class CodexProvider: AIProvider {
    let kind: AIProviderKind = .codex
    private(set) var state: AIProviderState = .unavailable("Codex")
    private(set) var models: [AIModel] = []
    private(set) var conversations: [AIConversationSummary] = []
    private(set) var usage: AIUsage?
    var onEvent: ((AIProviderEvent) -> Void)?

    private var transport: ProviderProcess?
    private var decoder = JSONLineDecoder()
    private var nextID = 1
    private var callbacks: [Int: ([String: Any]) -> Void] = [:]
    private var activeThreadID: String?
    private var activeMessageID: UUID?

    private static let quickChatInstructions = """
    This is a safe quick-answer surface inside OmniMac. Answer only from the user's supplied text and image. Do not run commands, call tools, inspect files, or modify the computer. If the request requires those actions, explain that the user must continue it in the official Codex client.
    """

    static func executable() -> URL? {
        let manager = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex"
        ] + ((try? manager.contentsOfDirectory(atPath: NSHomeDirectory() + "/.vscode/extensions")) ?? [])
            .filter { $0.hasPrefix("openai.chatgpt-") }
            .sorted(by: >)
            .map { NSHomeDirectory() + "/.vscode/extensions/\($0)/bin/macos-aarch64/codex" }
        return candidates.first(where: { manager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    func refresh() {
        guard transport == nil else { requestBootstrapData(); return }
        guard let executable = Self.executable() else { publish(.unavailable("Codex")); return }
        let process = ProviderProcess()
        process.onOutput = { [weak self] data in self?.receive(data) }
        process.onExit = { [weak self] code, _ in
            self?.transport = nil
            self?.publish(code == 0 ? .signedOut : .failed("Codex exited (\(code))"))
        }
        do {
            try process.start(.init(executable: executable, arguments: ["app-server", "--stdio"]))
            transport = process
            request("initialize", params: ["clientInfo": ["name": "omnimac", "title": "OmniMac", "version": "1.0"]]) { [weak self] _ in
                try? self?.transport?.writeJSON(["jsonrpc": "2.0", "method": "initialized"])
                self?.requestBootstrapData()
            }
        } catch { publish(.failed(error.localizedDescription)) }
    }

    func signIn() {
        refresh()
        request("account/login/start", params: ["type": "chatgpt"]) { _ in }
    }

    func startConversation(model: String?, effort: String?, prompt: String, imageURLs: [URL]) {
        var params: [String: Any] = [
            "cwd": NSHomeDirectory(),
            "approvalPolicy": "never",
            "sandbox": "read-only",
            "baseInstructions": Self.quickChatInstructions
        ]
        if let model { params["model"] = model }
        request("thread/start", params: params) { [weak self] result in
            guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { return }
            self?.activeThreadID = id
            self?.onEvent?(.conversationSelected(id))
            self?.startTurn(threadID: id, model: model, effort: effort, prompt: prompt, imageURLs: imageURLs)
        }
    }

    func resume(id: String, model: String?, effort: String?, prompt: String, imageURLs: [URL]) {
        request("thread/resume", params: ["threadId": id]) { [weak self] _ in
            self?.activeThreadID = id
            self?.onEvent?(.conversationSelected(id))
            self?.startTurn(threadID: id, model: model, effort: effort, prompt: prompt, imageURLs: imageURLs)
        }
    }

    func refreshUsage() { requestBootstrapData() }

    func loadTranscript(id: String) {
        activeThreadID = id
        request("thread/read", params: ["threadId": id, "includeTurns": true]) { [weak self] result in
            self?.onEvent?(.transcript(CodexProtocol.transcript(from: result)))
        }
    }

    func cancel() {
        guard let thread = activeThreadID else { return }
        request("turn/interrupt", params: ["threadId": thread]) { _ in }
    }

    func shutdown() { transport?.terminate(); transport = nil }

    private func requestBootstrapData() {
        request("account/read", params: [:]) { [weak self] result in
            self?.publish(result["account"] is NSNull || result["account"] == nil ? .signedOut : .ready)
        }
        request("model/list", params: ["limit": 100]) { [weak self] result in
            guard let self else { return }; models = CodexProtocol.models(from: result); onEvent?(.models(models))
        }
        request("thread/list", params: ["limit": 100, "sortKey": "updated_at", "sortDirection": "desc"]) { [weak self] result in
            guard let self else { return }; conversations = CodexProtocol.conversations(from: result); onEvent?(.conversations(conversations))
        }
        request("account/rateLimits/read", params: [:]) { [weak self] result in
            guard let self, let limits = result["rateLimits"] as? [String: Any] else { return }
            let windows = CodexProtocol.usageWindows(from: limits)
            guard !windows.isEmpty else { return }
            usage = AIUsage(windows: windows, inputTokens: nil, outputTokens: nil)
            onEvent?(.usage(usage))
        }
        request("account/usage/read", params: [:]) { _ in }
    }

    private func startTurn(threadID: String, model: String?, effort: String?, prompt: String, imageURLs: [URL]) {
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        for url in imageURLs { input.append(["type": "localImage", "path": url.path]) }
        var params: [String: Any] = ["threadId": threadID, "input": input, "approvalPolicy": "never"]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        request("turn/start", params: params) { _ in }
    }

    private func request(_ method: String, params: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard let transport else { return }
        let id = nextID; nextID += 1; callbacks[id] = completion
        try? transport.writeJSON(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func receive(_ data: Data) {
        guard let objects = try? decoder.feed(data) else { return }
        for case let object as [String: Any] in objects {
            if let id = object["id"] as? Int, let error = object["error"] as? [String: Any] {
                callbacks.removeValue(forKey: id)
                let message = error["message"] as? String ?? L("Ошибка провайдера", "Provider error")
                onEvent?(.failed(message))
                continue
            }
            if let id = object["id"] as? Int, let result = object["result"] as? [String: Any] {
                callbacks.removeValue(forKey: id)?(result); continue
            }
            guard let method = object["method"] as? String, let params = object["params"] as? [String: Any] else { continue }
            if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
                let id = activeMessageID ?? UUID(); if activeMessageID == nil { activeMessageID = id; onEvent?(.messageStarted(id)) }
                onEvent?(.messageDelta(id, delta))
            } else if method == "turn/completed" {
                // Un turno fallido (p. ej. límite de uso) no trae texto: hay que cerrar igualmente el estado «escribiendo».
                let turn = params["turn"] as? [String: Any]
                if turn?["status"] as? String == "failed" {
                    let message = (turn?["error"] as? [String: Any])?["message"] as? String ?? L("Codex не смог ответить", "Codex could not answer")
                    onEvent?(.failed(message))
                }
                onEvent?(.messageCompleted(activeMessageID ?? UUID(), nil))
                activeMessageID = nil; requestBootstrapData()
            } else if method.contains("approval") {
                onEvent?(.failed(L("Действие требует открытия официального Codex", "Open official Codex to approve this action")))
            }
        }
    }

    private func publish(_ newState: AIProviderState) { state = newState; onEvent?(.state(newState)) }
}
