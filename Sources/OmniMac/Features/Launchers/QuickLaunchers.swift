import AppKit
import ApplicationServices

/// Запуск почты: приложение Outlook, если оно установлено, иначе Outlook в браузере.
/// Число непрочитанных берётся у запущенного Outlook через AppleScript (только чтение) и только когда notch открыт.
final class MailLauncher: ObservableObject {
    @Published private(set) var unread = 0

    static let bundleID = "com.microsoft.Outlook"
    static let webURL = URL(string: "https://outlook.office.com/mail")!

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) }
    private var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }
    private var refreshing = false

    var helpText: String {
        appURL != nil ? L("Открыть Microsoft Outlook", "Open Microsoft Outlook") : L("Открыть Outlook в браузере", "Open Outlook in the browser")
    }

    func open() {
        if let appURL { NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) }
        else { NSWorkspace.shared.open(Self.webURL) }
    }

    /// Не запускает Outlook сам: если он закрыт, счётчик просто сбрасывается.
    /// В новом Outlook AppleScript всегда отвечает нулями, поэтому число берётся из бокового списка папок его окна
    /// («Входящие; Непрочитанных сообщений: 8»), а в классическом Outlook остаётся запасной путь через AppleScript.
    func refresh() {
        guard !refreshing else { return }
        guard isRunning, Permissions.hasAccessibility else {
            if unread != 0 { unread = 0 }
            return
        }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readUnreadFromWindow() ?? Self.readUnreadViaScript() ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                if self.unread != result { self.unread = result }
            }
        }
    }

    private static func readUnreadViaScript() -> Int? {
        guard let script = NSAppleScript(source: "tell application id \"\(bundleID)\" to get unread count of inbox") else { return nil }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        return error == nil ? Int(descriptor.int32Value) : nil
    }

    /// Ищет в окне ячейку папки «Входящие» и достаёт из её подписи число после «Непрочитанных сообщений:» / «Unread:».
    private static func readUnreadFromWindow() -> Int? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Без этого признака Chromium/WebView-приложение отдаёт только кнопки окна.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for window in windows {
            if let label = findInboxLabel(in: window, depth: 0), let count = unreadCount(inLabel: label) { return count }
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static let inboxNames = ["входящие", "inbox"]

    private static func findInboxLabel(in element: AXUIElement, depth: Int) -> String? {
        guard depth <= 24 else { return nil }
        let role = attribute(element, kAXRoleAttribute) as? String
        if role == "AXCell" {
            // В новом Outlook подпись ячейки лежит в описании, в старом — в заголовке.
            for name in [kAXDescriptionAttribute, kAXTitleAttribute] {
                if let text = attribute(element, name) as? String, isInboxLabel(text) { return text }
            }
        }
        for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            if let found = findInboxLabel(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    static func isInboxLabel(_ label: String) -> Bool {
        let first = label.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return inboxNames.contains(first)
    }

    /// «Входящие; Непрочитанных сообщений: 8» → 8. Без слова про непрочитанные (папка пуста или всё прочитано) → 0.
    static func unreadCount(inLabel label: String) -> Int? {
        guard isInboxLabel(label) else { return nil }
        let lower = label.lowercased()
        guard lower.contains("непрочитан") || lower.contains("unread") else { return 0 }
        guard let range = label.range(of: "[0-9]+", options: .regularExpression) else { return 0 }
        return Int(label[range])
    }
}

/// Состояние VPN FortiClient. FortiClient регистрирует в macOS обычный сетевой сервис VPN, поэтому статус читается через
/// `scutil --nc status`. Включить или выключить туннель снаружи нельзя: параметры подключения и пароль живут внутри самого
/// FortiClient, поэтому кнопка выводит его окно на передний план.
final class VPNMonitor: ObservableObject {
    enum Status: Equatable { case unavailable, disconnected, connecting, connected, disconnecting }

    @Published private(set) var status: Status = .unavailable
    /// Идёт подключение или отключение через окно FortiClient; ошибка — для показа в окне ввода.
    @Published private(set) var busy = false
    @Published var message: String?

    static let providerID = "com.fortinet.forticlient.macos.vpn"
    private var serviceID: String?
    private var refreshing = false

    private var clientURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.fortinet.FortiClient") ?? URL(fileURLWithPath: "/Applications/FortiClient.app") }

    /// Подставляет логин и пароль в форму FortiClient и нажимает «Соединить» (по желанию пароль сохраняется в связке ключей).
    func connect(username: String, password: String, save: Bool) {
        guard !busy else { return }
        if save { VPNCredentialsStore.save(username: username, password: password) }
        else { VPNCredentialsStore.rememberUsername(username) }
        run { try FortiClientAutomation.connect(username: username, password: password) }
    }

    func disconnect() {
        guard !busy else { return }
        run { try FortiClientAutomation.disconnect() }
    }

    private func run(_ work: @escaping () throws -> Void) {
        busy = true; message = nil
        if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: String?
            do { try work() } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.message = failure
                self.refresh()
            }
        }
    }

    func openClient() {
        guard let url = clientURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var helpText: String {
        switch status {
        case .unavailable: return "FortiClient VPN"
        case .disconnected: return L("VPN отключён · подключить", "VPN disconnected · connect")
        case .connecting: return L("VPN подключается…", "VPN connecting…")
        case .connected: return L("VPN подключён", "VPN connected")
        case .disconnecting: return L("VPN отключается…", "VPN disconnecting…")
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let known = serviceID
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let id = known ?? Self.findService()
            let status = id.map(Self.readStatus) ?? .unavailable
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.serviceID = id
                if self.status != status { self.status = status }
            }
        }
    }

    private static func run(_ arguments: [String]) -> String {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        task.arguments = arguments
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Строка вида: `* (Disconnected)   <UUID> VPN (com.fortinet.forticlient.macos.vpn) "VPN" [...]`.
    static func serviceID(inList list: String) -> String? {
        for line in list.split(separator: "\n") where line.contains(providerID) {
            if let range = line.range(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", options: .regularExpression) {
                return String(line[range])
            }
        }
        return nil
    }

    static func status(fromOutput output: String) -> Status {
        switch output.split(separator: "\n").first?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "connected": return .connected
        case "connecting", "reasserting": return .connecting
        case "disconnecting": return .disconnecting
        case "disconnected": return .disconnected
        default: return .unavailable
        }
    }

    private static func findService() -> String? { serviceID(inList: run(["--nc", "list"])) }
    private static func readStatus(_ id: String) -> Status { status(fromOutput: run(["--nc", "status", id])) }
}
