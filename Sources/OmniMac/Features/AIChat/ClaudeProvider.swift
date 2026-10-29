import AppKit
import Foundation

final class ClaudeProvider: AIProvider {
    let kind: AIProviderKind = .claude
    private(set) var state: AIProviderState = .unavailable("Claude Code")
    private(set) var models = [AIModel(id: "fable", name: "Fable", efforts: ClaudeProvider.efforts, defaultEffort: "medium"), AIModel(id: "opus", name: "Opus", efforts: ClaudeProvider.efforts, defaultEffort: "medium"),
                                AIModel(id: "sonnet", name: "Sonnet", efforts: ClaudeProvider.efforts, defaultEffort: "medium"), AIModel(id: "haiku", name: "Haiku", efforts: ClaudeProvider.efforts, defaultEffort: "medium")]
    private(set) var conversations: [AIConversationSummary] = []
    private(set) var usage: AIUsage?
    var onEvent: ((AIProviderEvent) -> Void)?
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    private var process: ProviderProcess?
    private var probe: ProviderProcess?   // se retiene: al soltarlo, deinit mata el proceso
    private var decoder = JSONLineDecoder()
    private var messageID: UUID?

    private var executable: URL? {
        let manager = FileManager.default
        let extensions = ((try? manager.contentsOfDirectory(atPath: NSHomeDirectory() + "/.vscode/extensions")) ?? [])
            .filter { $0.hasPrefix("anthropic.claude-code-") }.sorted(by: >)
            .map { NSHomeDirectory() + "/.vscode/extensions/\($0)/resources/native-binary/claude" }
        return (["/opt/homebrew/bin/claude", "/usr/local/bin/claude", NSHomeDirectory() + "/.local/bin/claude"] + extensions)
            .first(where: { manager.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    /// El cliente no ofrece una orden para consultar los límites: llegan en cada respuesta como «rate_limit_event».
    /// Se guardan para enseñarlos aunque aún no se haya preguntado nada en esta sesión de OmniMac.
    private static let usageKey = "ai.claude.usage"

    func refreshUsage() {
        if usage == nil, let saved = UserDefaults.standard.data(forKey: Self.usageKey),
           let windows = try? JSONDecoder().decode([StoredWindow].self, from: saved) {
            usage = AIUsage(windows: windows.map { AIUsageWindow(title: $0.title, remainingPercent: $0.remaining, resetsAt: $0.resetsAt) })
            onEvent?(.usage(usage))
        }
        guard let executable, process == nil, probe == nil else { return }
        // Una pregunta mínima al modelo más pequeño: es la única forma de que el cliente informe del límite actual.
        let probe = ProviderProcess(); self.probe = probe; var probeDecoder = JSONLineDecoder()
        probe.onOutput = { [weak self] data in
            guard let objects = try? probeDecoder.feed(data) else { return }
            for case let object as [String: Any] in objects { self?.readUsage(object) }
        }
        probe.onExit = { [weak self] _, _ in DispatchQueue.main.async { self?.probe = nil } }
        do {
            try probe.start(.init(executable: executable, arguments: ["-p", "--model", "haiku", "--output-format", "stream-json", "--verbose", "--tools", "", "--append-system-prompt", "Reply with: ok", "ok"]))
        } catch {}
    }

    private struct StoredWindow: Codable { var title: String; var remaining: Double; var resetsAt: Date? }

    private func readUsage(_ object: [String: Any]) {
        guard object["type"] as? String == "rate_limit_event",
              let info = object["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any] else { return }
        let rows: [(String, String)] = [("five_hour", L("Сессия · 5 ч", "Session · 5 h")), ("seven_day", L("Неделя", "Week"))]
        let parsed = rows.compactMap { key, title -> AIUsageWindow? in
            guard let row = windows[key] as? [String: Any], let used = (row["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return AIUsageWindow(title: title, remainingPercent: max(0, 100 - used * 100),
                resetsAt: (row["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        guard !parsed.isEmpty else { return }
        usage = AIUsage(windows: parsed)
        if let data = try? JSONEncoder().encode(parsed.map { StoredWindow(title: $0.title, remaining: $0.remainingPercent, resetsAt: $0.resetsAt) }) {
            UserDefaults.standard.set(data, forKey: Self.usageKey)
        }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(.usage(self?.usage)) }
    }

    /// El cliente publica su lista real de modelos (la misma que VS Code) en la respuesta a «initialize».
    private var modelsProbe: ProviderProcess?
    private static let modelsKey = "ai.claude.models"

    private func loadModels() {
        if let saved = UserDefaults.standard.data(forKey: Self.modelsKey),
           let cached = try? JSONDecoder().decode([AIModel].self, from: saved), !cached.isEmpty {
            models = cached; onEvent?(.models(cached))
        }
        guard let executable, modelsProbe == nil else { return }
        let probe = ProviderProcess(); modelsProbe = probe
        var decoder = JSONLineDecoder()
        probe.onOutput = { [weak self] data in
            guard let objects = try? decoder.feed(data) else { return }
            for case let object as [String: Any] in objects where object["type"] as? String == "control_response" {
                let response = (object["response"] as? [String: Any])?["response"] as? [String: Any]
                let parsed = (response?["models"] as? [[String: Any]] ?? []).compactMap(Self.model(from:))
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !parsed.isEmpty {
                        self.models = parsed; self.onEvent?(.models(parsed))
                        if let data = try? JSONEncoder().encode(parsed) { UserDefaults.standard.set(data, forKey: Self.modelsKey) }
                    }
                    self.modelsProbe?.terminate(); self.modelsProbe = nil
                }
            }
        }
        probe.onExit = { [weak self] _, _ in DispatchQueue.main.async { self?.modelsProbe = nil } }
        do {
            try probe.start(.init(executable: executable, arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--tools", ""]))
            try probe.writeJSON(["type": "control_request", "request_id": "omnimac-models", "request": ["subtype": "initialize"]])
        } catch { modelsProbe = nil }
    }

    private static func model(from row: [String: Any]) -> AIModel? {
        guard let id = row["value"] as? String else { return nil }
        let efforts = row["supportedEffortLevels"] as? [String] ?? []
        return AIModel(id: id, name: row["displayName"] as? String ?? id, efforts: efforts,
                       defaultEffort: efforts.contains("medium") ? "medium" : efforts.first, detail: row["description"] as? String)
    }

    func refresh() {
        loadModels()
        conversations = ClaudeHistory.sessions()
        onEvent?(.models(models)); onEvent?(.conversations(conversations))
        guard let executable else { state = .unavailable("Claude Code"); onEvent?(.state(state)); return }
        // «auth status» solo lee el estado local de la sesión: no toca credenciales.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process(), pipe = Pipe()
            task.executableURL = executable; task.arguments = ["auth", "status"]
            task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
            try? task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            let loggedIn = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["loggedIn"] as? Bool ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = loggedIn ? .ready : .signedOut
                self.onEvent?(.state(self.state))
            }
        }
    }
    func signIn() {
        guard let executable else {
            NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/en/docs/claude-code/getting-started")!)
            return
        }
        let process = Process(); process.executableURL = executable; process.arguments = ["auth", "login"]
        try? process.run()
    }
    func startConversation(model: String?, effort: String?, prompt: String, imageURLs: [URL]) { run(sessionID: nil, model: model, effort: effort, prompt: prompt, imageURLs: imageURLs) }
    func resume(id: String, model: String?, effort: String?, prompt: String, imageURLs: [URL]) { run(sessionID: id, model: model, effort: effort, prompt: prompt, imageURLs: imageURLs) }
    func loadTranscript(id: String) { onEvent?(.transcript(ClaudeHistory.transcript(id: id))) }
    func cancel() { process?.cancel() }
    func shutdown() { process?.terminate(); process = nil }

    private func run(sessionID: String?, model: String?, effort: String?, prompt: String, imageURLs: [URL]) {
        guard let executable else { onEvent?(.state(.unavailable("Claude Code"))); return }
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "plan", "--tools", "",
            "--append-system-prompt",
            "This is a safe quick-answer surface inside OmniMac. Answer only from the supplied prompt and attached screenshot, if any. Do not run commands, call tools, inspect files, or modify the computer."
        ]
        if let model { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        if let sessionID { arguments += ["--resume", sessionID] }
        // Sin herramientas el cliente no puede abrir ficheros: la captura viaja dentro del propio mensaje (base64).
        var inputMessage: [String: Any]?
        let images = imageURLs.compactMap { try? Data(contentsOf: $0) }
        if !images.isEmpty {
            arguments += ["--input-format", "stream-json"]
            var content: [[String: Any]] = images.map { ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]] }
            content.append(["type": "text", "text": prompt])
            inputMessage = ["type": "user", "message": ["role": "user", "content": content]]
        } else {
            arguments.append(prompt)
        }
        let transport = ProviderProcess(); process = transport
        transport.onOutput = { [weak self] data in self?.receive(data) }
        transport.onExit = { [weak self] code, _ in
            guard let self else { return }; process = nil
            if code != 0 { onEvent?(.failed("Claude Code exited (\(code))")) }
            if let id = messageID { onEvent?(.messageCompleted(id, nil)); messageID = nil }
            refresh()
        }
        do {
            try transport.start(.init(executable: executable, arguments: arguments))
            if let inputMessage { try transport.writeJSON(inputMessage); transport.closeInput() }
        }
        catch { onEvent?(.failed(error.localizedDescription)) }
    }

    private func receive(_ data: Data) {
        guard let objects = try? decoder.feed(data) else { return }
        for case let object as [String: Any] in objects {
            let type = object["type"] as? String
            readUsage(object)
            if let sessionID = object["session_id"] as? String { onEvent?(.conversationSelected(sessionID)) }
            let text = object["result"] as? String
                ?? ((object["message"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            // «result» repite el texto ya emitido en los mensajes «assistant»: solo vale si no hubo ninguno.
            guard let text, !text.isEmpty, type == "assistant" || (type == "result" && messageID == nil) else { continue }
            let id = messageID ?? UUID(); if messageID == nil { messageID = id; onEvent?(.messageStarted(id)) }
            onEvent?(.messageDelta(id, text))
        }
    }
}
