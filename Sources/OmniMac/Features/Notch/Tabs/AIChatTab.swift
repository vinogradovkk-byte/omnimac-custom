import SwiftUI

/// Panel AI del notch (diseño: .superpowers/brainstorm/ai-panel-mockup-v2.html).
/// El panel es siempre negro: los colores van explícitos para no depender de la apariencia del sistema.
struct AIChatTab: View {
    @ObservedObject var coordinator: AIChatCoordinator
    @State private var showHistory = false
    @State private var showUsage = false
    @State private var showModels = false

    private let purple = Color(red: 0.50, green: 0.35, blue: 0.84)
    private let field = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let line = Color(red: 0.19, green: 0.20, blue: 0.24)

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            content
            if isReady, let error = coordinator.errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error).lineLimit(2)
                    Spacer()
                    Button { coordinator.errorText = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.font(.system(size: 10)).foregroundStyle(.orange)
            }
            if isReady { composer }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 6)
        .onAppear { coordinator.start() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(AIProviderKind.allCases) { kind in
                    Button { coordinator.selectedProvider = kind } label: {
                        Text(kind.title).font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 16).padding(.vertical, 6)
                            .foregroundStyle(coordinator.selectedProvider == kind ? Color.white : Color.white.opacity(0.5))
                            .background(RoundedRectangle(cornerRadius: 8).fill(coordinator.selectedProvider == kind ? Color.white.opacity(0.14) : .clear))
                    }.buttonStyle(.plain).disabled(coordinator.isStreaming)
                }
            }.padding(3).background(RoundedRectangle(cornerRadius: 11).fill(field))
            Spacer(minLength: 4)
            if isReady {
            iconButton("square.and.pencil", help: L("Новый чат", "New chat")) { coordinator.newChat() }.disabled(coordinator.isStreaming)
            iconButton("clock.arrow.circlepath", help: L("История", "History")) { showHistory.toggle() }
                .popover(isPresented: $showHistory) { historyView.frame(width: 360, height: 360).environment(\.colorScheme, .dark) }
            }
        }
    }

    private var isReady: Bool { coordinator.states[coordinator.selectedProvider] == .ready }

    private var usageButton: some View {
        Button { showUsage.toggle(); if showUsage { coordinator.refreshUsage() } } label: {
            Text("Usage").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(red: 0.77, green: 0.66, blue: 1))
                .padding(.horizontal, 10).padding(.vertical, 7).background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
        }.buttonStyle(.plain)
        .popover(isPresented: $showUsage) { usageView.padding(18).frame(width: 300).background(Color(red: 0.09, green: 0.10, blue: 0.12)).environment(\.colorScheme, .dark) }
    }

    /// Ползунок по уровням, которые заявляет сам клиент для выбранной модели.
    @ViewBuilder private var effortSlider: some View {
        let steps = coordinator.effortSteps
        if steps.count > 1 {
            let current = coordinator.effort(for: coordinator.selectedProvider) ?? steps[0]
            let index = Binding<Double>(
                get: { Double(steps.firstIndex(of: current) ?? 0) },
                set: { coordinator.selectedEfforts[coordinator.selectedProvider] = steps[min(steps.count - 1, max(0, Int($0.rounded())))] })
            HStack(spacing: 6) {
                Slider(value: index, in: 0...Double(steps.count - 1), step: 1).frame(width: 90).tint(purple).controlSize(.small)
                Text(AIModel.effortTitle(current)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).frame(minWidth: 62, alignment: .leading).lineLimit(1)
            }.help(L("Уровень размышления", "Reasoning effort"))
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
        }.buttonStyle(.plain).help(help)
    }

    private var modelMenu: some View {
        Button { showModels.toggle() } label: {
            HStack(spacing: 5) {
                Text(coordinator.currentModel?.name ?? L("Модель", "Model")).font(.system(size: 12)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
        }.buttonStyle(.plain)
        .popover(isPresented: $showModels, arrowEdge: .top) {
            let list = coordinator.models[coordinator.selectedProvider] ?? []
            // Alto exacto según el número de modelos: sin barra de desplazamiento salvo que la lista sea enorme.
            let rowHeight: CGFloat = 33
            let limit = min(640, (NSScreen.main?.frame.height ?? 800) * 0.8)
            let wanted = CGFloat(list.count) * rowHeight + 10
            let rows = VStack(alignment: .leading, spacing: 0) {
                ForEach(list) { model in
                    Button { coordinator.selectedModels[coordinator.selectedProvider] = model.id; showModels = false } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                if let detail = model.detail { Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                            }
                            Spacer(minLength: 6)
                            if model.id == coordinator.currentModel?.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(purple) }
                        }
                        .padding(.horizontal, 10).frame(height: rowHeight).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7).fill(model.id == coordinator.currentModel?.id ? Color.white.opacity(0.08) : .clear))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(5)
            Group {
                if wanted > limit { ScrollView { rows }.frame(width: 320, height: limit) } else { rows.frame(width: 320) }
            }
            .background(Color(red: 0.09, green: 0.10, blue: 0.12)).environment(\.colorScheme, .dark).foregroundStyle(.white)
        }
    }

    @ViewBuilder private var content: some View {
        switch coordinator.states[coordinator.selectedProvider] ?? .unavailable(coordinator.selectedProvider.title) {
        case .unavailable(let name):
            centered {
                Text("\(name) " + L("не установлен", "is not installed")).foregroundStyle(.white.opacity(0.7))
                actionButton(L("Открыть официальную установку", "Open official installation")) { coordinator.signIn() }
            }
        case .signedOut:
            centered { actionButton(L("Войти через браузер", "Sign in with browser")) { coordinator.signIn() } }
        case .failed(let error): centered { Text(error).foregroundStyle(.orange) }
        case .ready:
            let list = coordinator.messages[coordinator.selectedProvider] ?? []
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) { ForEach(list) { messageRow($0).id($0.id) } }.padding(.horizontal, 6)
                }
                .overlay { if list.isEmpty { Text(L("Задайте быстрый вопрос", "Ask a quick question")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.35)) } }
                .onChange(of: list.last?.text) { _ in if let id = list.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(spacing: 10) { body() }.font(.system(size: 13)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 9).fill(purple)) }.buttonStyle(.plain)
    }

    /// Миниатюра снимка; сам файл остаётся на диске, пока открыт OmniMac, чтобы его можно было открыть.
    private func thumbnail(_ url: URL, size: CGSize) -> some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else { Color.white.opacity(0.1) }
        }
        .frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(line))
        .contentShape(Rectangle())
    }

    private var attachmentStrip: some View {
        HStack(spacing: 6) {
            ForEach(coordinator.attachments, id: \.self) { url in
                thumbnail(url, size: CGSize(width: 62, height: 40))
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .overlay(alignment: .topTrailing) {
                        Button { coordinator.removeAttachment(url) } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white, .black.opacity(0.75))
                        }.buttonStyle(.plain).offset(x: 5, y: -5).help(L("Убрать снимок", "Remove screenshot"))
                    }
            }
            Text("\(coordinator.attachments.count)/\(AIChatCoordinator.maxAttachments)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if !coordinator.attachments.isEmpty { attachmentStrip }
            TextField(L("Задайте быстрый вопрос…", "Ask a quick question…"), text: $coordinator.draft, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4).padding(.horizontal, 7).padding(.top, 5)
                .onSubmit { coordinator.send() }
            HStack(spacing: 8) {
                Button { coordinator.captureScreen() } label: {
                    Label(L("Посмотреть экран", "View screen"), systemImage: "display").font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain)
                modelMenu
                effortSlider
                usageButton
                Spacer(minLength: 4)
                Button { coordinator.isStreaming ? coordinator.cancel() : coordinator.send() } label: {
                    Text(coordinator.isStreaming ? L("Стоп ■", "Stop ■") : L("Отправить ↑", "Send ↑")).font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 14).padding(.vertical, 7).background(RoundedRectangle(cornerRadius: 9).fill(purple))
                }.buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16).fill(field).overlay(RoundedRectangle(cornerRadius: 16).stroke(line)))
    }

    private var historyView: some View {
        let list = coordinator.conversations[coordinator.selectedProvider] ?? []
        return List(list) { chat in
            Button { coordinator.resume(chat); showHistory = false } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title).lineLimit(1)
                    HStack { Text(chat.updatedAt.formatted(date: .abbreviated, time: .shortened)); if let root = chat.root { Text("· " + URL(fileURLWithPath: root).lastPathComponent) } }
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.overlay { if list.isEmpty { Text(L("История пуста", "No history")).foregroundStyle(.secondary) } }
    }

    @ViewBuilder private var usageView: some View {
        if let usage = coordinator.usages[coordinator.selectedProvider], !usage.windows.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Usage").font(.headline)
                ForEach(usage.windows, id: \.title) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(window.title); Spacer(); Text("\(Int(window.remainingPercent.rounded()))% " + L("осталось", "left")).foregroundStyle(.secondary) }
                        ProgressView(value: window.remainingPercent, total: 100).tint(window.remainingPercent < 15 ? .orange : purple)
                        if let reset = window.resetsAt { Text(L("Сброс: ", "Resets: ") + reset.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } else { Text(L("Остаток подписки не предоставлен клиентом", "The client does not expose remaining subscription quota")) }
    }

    private func messageRow(_ message: AIMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 80) }
            VStack(alignment: .leading, spacing: 5) {
                if !isUser { Text("\(coordinator.selectedProvider.title.uppercased())").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(red: 0.62, green: 0.48, blue: 0.92)) }
                Text(message.text.isEmpty ? "…" : message.text).font(.system(size: 13)).textSelection(.enabled)
                if !message.images.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(message.images, id: \.self) { url in
                            thumbnail(url, size: CGSize(width: 84, height: 52)).onTapGesture { NSWorkspace.shared.open(url) }
                                .help(L("Открыть снимок", "Open screenshot"))
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 15).fill(isUser ? Color(red: 0.16, green: 0.18, blue: 0.21) : field).overlay(RoundedRectangle(cornerRadius: 15).stroke(isUser ? .clear : line)))
            if !isUser { Spacer(minLength: 80) }
        }.padding(.vertical, 5)
    }
}
