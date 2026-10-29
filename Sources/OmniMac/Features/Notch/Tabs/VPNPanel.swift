import SwiftUI

/// Окно у кнопки VPN: статус, логин и пароль, «Подключиться». Данные уходят в форму FortiClient и подтверждаются его кнопкой.
struct VPNPanel: View {
    @ObservedObject var vpn: VPNMonitor
    @State private var username = ""
    @State private var password = ""
    @State private var save = false
    @State private var hasSaved = false

    private let purple = Color(red: 0.50, green: 0.35, blue: 0.84)
    private let field = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let line = Color(red: 0.19, green: 0.20, blue: 0.24)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text("FortiClient VPN").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }

            switch vpn.status {
            case .connected, .disconnecting:
                actionButton(L("Отключить", "Disconnect"), fill: Color.red.opacity(0.75), enabled: vpn.status == .connected && !vpn.busy) { vpn.disconnect() }
            case .connecting:
                Text(L("Подключается… если FortiClient просит код, введите его в его окне.", "Connecting… if FortiClient asks for a code, enter it in its window."))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            default:
                loginForm
            }

            if let message = vpn.message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Button { vpn.openClient() } label: {
                Text(L("Открыть окно FortiClient", "Open FortiClient")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }.buttonStyle(.plain)
        }
        .padding(14).frame(width: 300)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .onAppear(perform: load)
    }

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L("Имя пользователя", "Username"), text: $username).textFieldStyle(.plain).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
            SecureField(L("Пароль", "Password"), text: $password).textFieldStyle(.plain).padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
                .onSubmit(connect)
            Toggle(isOn: $save) {
                Text(L("Сохранить пароль в связке ключей macOS", "Save the password in the macOS Keychain")).font(.system(size: 11))
            }.toggleStyle(.checkbox)
            actionButton(vpn.busy ? L("Подключаю…", "Connecting…") : L("Подключиться", "Connect"), fill: purple,
                         enabled: !vpn.busy && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty, action: connect)
            if hasSaved {
                Button { VPNCredentialsStore.forget(); hasSaved = false; password = ""; save = false } label: {
                    Text(L("Забыть сохранённый пароль", "Forget the saved password")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                }.buttonStyle(.plain)
            }
        }
    }

    private func actionButton(_ title: String, fill: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9).fill(fill.opacity(enabled ? 1 : 0.35)))
        }.buttonStyle(.plain).disabled(!enabled)
    }

    private func connect() {
        let name = username.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !password.isEmpty else { return }
        vpn.connect(username: name, password: password, save: save)
    }

    /// Логин берётся из прошлого раза или из формы FortiClient; пароль из связки ключей читается с фонового потока.
    private func load() {
        username = VPNCredentialsStore.savedUsername ?? ""
        hasSaved = VPNCredentialsStore.savedUsername != nil
        let known = VPNCredentialsStore.savedUsername
        DispatchQueue.global(qos: .userInitiated).async {
            let name = known ?? FortiClientAutomation.usernameFromClient()
            let saved = known.flatMap(VPNCredentialsStore.loadPassword(for:))
            DispatchQueue.main.async {
                if username.isEmpty, let name { username = name }
                if let saved, password.isEmpty { password = saved; save = true; hasSaved = true } else { hasSaved = known != nil && saved != nil }
            }
        }
    }

    private var statusColor: Color {
        switch vpn.status {
        case .connected: return .green
        case .connecting, .disconnecting: return .yellow
        default: return Color.white.opacity(0.35)
        }
    }

    private var statusText: String {
        switch vpn.status {
        case .connected: return L("Подключён", "Connected")
        case .connecting: return L("Подключается", "Connecting")
        case .disconnecting: return L("Отключается", "Disconnecting")
        case .disconnected: return L("Отключён", "Disconnected")
        case .unavailable: return ""
        }
    }
}
