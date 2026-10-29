import AppKit
import ApplicationServices
import Security

/// Управление окном FortiClient через «Универсальный доступ». Подключиться без него нельзя: адрес сервера, логин и пароль
/// получает системное расширение Fortinet только от самого FortiClient. Поэтому OmniMac подставляет логин и пароль в форму
/// FortiClient и нажимает его кнопку «Соединить». Двухфакторный код (если он есть) вводится в FortiClient.
enum FortiClientAutomation {
    static let bundleID = "com.fortinet.FortiClient"

    enum Failure: LocalizedError {
        case notTrusted, notInstalled, windowNotFound, formNotFound, buttonNotFound, notConnected

        var errorDescription: String? {
            switch self {
            case .notTrusted: return L("Нужен доступ «Универсальный доступ» для OmniMac", "OmniMac needs the Accessibility permission")
            case .notInstalled: return L("FortiClient не найден", "FortiClient was not found")
            case .windowNotFound: return L("Окно FortiClient не открылось", "The FortiClient window did not open")
            case .formNotFound: return L("В FortiClient сейчас не форма входа (возможно, VPN уже подключён)", "FortiClient is not showing the sign-in form (the VPN may already be connected)")
            case .buttonNotFound: return L("Не нашёл кнопку в окне FortiClient", "Could not find the button in the FortiClient window")
            case .notConnected: return L("VPN не подключён", "The VPN is not connected")
            }
        }
    }

    // MARK: - Подключение и отключение

    static func connect(username: String, password: String) throws {
        let window = try preparedWindow()
        let fields = elements(in: window) { role($0) == "AXTextField" }
        guard fields.count >= 2 else { throw Failure.formNotFound }
        // Порядок полей в форме: имя пользователя, пароль.
        set(fields[0], username)
        set(fields[1], password)
        usleep(250_000)
        guard let button = primaryButton(in: window) else { throw Failure.buttonNotFound }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw Failure.buttonNotFound }
    }

    static func disconnect() throws {
        let window = try preparedWindow()
        // В окне подключённого FortiClient единственная кнопка с подписью — «Разъединить»; названия ищем по корням слов на случай другой локализации.
        let words = ["disconnect", "отключ", "разорв", "разъедин"]
        let titled = elements(in: window) { role($0) == "AXButton" && !(title($0) ?? "").isEmpty }
        let button = titled.first { element in words.contains { (title(element) ?? "").lowercased().contains($0) } } ?? titled.first
        guard let button else { throw Failure.notConnected }
        guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw Failure.buttonNotFound }
    }

    /// Логин из формы FortiClient — подсказка для первого запуска.
    static func usernameFromClient() -> String? {
        guard AXIsProcessTrusted(), let app = runningClient(), let window = try? firstWindow(of: app) else { return nil }
        let fields = elements(in: window) { role($0) == "AXTextField" }
        return fields.first.flatMap { stringValue($0) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Окно FortiClient

    private static func runningClient() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Запускает FortiClient при необходимости, включает режим доступности Electron и ждёт появления окна.
    private static func preparedWindow() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw Failure.notTrusted }
        var app = runningClient()
        if app == nil {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw Failure.notInstalled }
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in semaphore.signal() }
            _ = semaphore.wait(timeout: .now() + 10)
            for _ in 0..<40 where app == nil { usleep(250_000); app = runningClient() }
        }
        guard let app else { throw Failure.notInstalled }
        // Окно должно быть на экране: без этого Electron не отдаёт содержимое формы.
        DispatchQueue.main.sync { _ = app.activate(options: []) }
        for _ in 0..<40 {
            if let window = try? firstWindow(of: app), !elements(in: window, matching: { role($0) == "AXTextField" || role($0) == "AXButton" }).isEmpty {
                return window
            }
            usleep(250_000)
        }
        throw Failure.windowNotFound
    }

    private static func firstWindow(of app: NSRunningApplication) throws -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Без этого признака Chromium/Electron отдаёт только кнопки окна, но не его содержимое.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement], let window = windows.first else { throw Failure.windowNotFound }
        return window
    }

    /// Главная кнопка формы: первая кнопка с подписью (у кнопок окна — закрыть, свернуть — подписи нет).
    private static func primaryButton(in window: AXUIElement) -> AXUIElement? {
        elements(in: window) { role($0) == "AXButton" && !(title($0) ?? "").isEmpty }.first
    }

    // MARK: - Работа с деревом доступности

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func role(_ element: AXUIElement) -> String? { attribute(element, kAXRoleAttribute) as? String }
    private static func title(_ element: AXUIElement) -> String? { attribute(element, kAXTitleAttribute) as? String }
    private static func stringValue(_ element: AXUIElement) -> String? { attribute(element, kAXValueAttribute) as? String }

    private static func set(_ element: AXUIElement, _ value: String) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    }

    private static func elements(in root: AXUIElement, matching predicate: (AXUIElement) -> Bool, depth: Int = 0) -> [AXUIElement] {
        guard depth <= 14 else { return [] }
        var result: [AXUIElement] = predicate(root) ? [root] : []
        for child in (attribute(root, kAXChildrenAttribute) as? [AXUIElement] ?? []) {
            result += elements(in: child, matching: predicate, depth: depth + 1)
        }
        return result
    }

    private static func elements(in root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        elements(in: root, matching: predicate)
    }
}

/// Пароль VPN — только в связке ключей macOS и только если вы поставили галочку «Сохранить».
enum VPNCredentialsStore {
    private static let service = "com.seergiii.omnimac.vpn"
    private static let usernameKey = "vpn.username"

    static var savedUsername: String? { UserDefaults.standard.string(forKey: usernameKey) }

    static func loadPassword(for username: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: username, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(username: String, password: String) {
        delete(username: username)
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: username, kSecValueData as String: Data(password.utf8),
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        SecItemAdd(attributes as CFDictionary, nil)
        UserDefaults.standard.set(username, forKey: usernameKey)
    }

    static func delete(username: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: username]
        SecItemDelete(query as CFDictionary)
    }

    static func rememberUsername(_ username: String) { UserDefaults.standard.set(username, forKey: usernameKey) }

    static func forget() {
        if let name = savedUsername { delete(username: name) }
        UserDefaults.standard.removeObject(forKey: usernameKey)
    }
}
