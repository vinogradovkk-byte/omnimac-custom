import SwiftUI

/// Вкладка Asana: мои задачи по статусам (колонкам доски), строки раскрываются до описания, подзадач и комментариев. Только чтение.
struct AsanaTab: View {
    @ObservedObject var store: AsanaStore

    private let purple = Color(red: 0.50, green: 0.35, blue: 0.84)
    private let coral = Color(red: 0.96, green: 0.42, blue: 0.42)
    private let field = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let line = Color(red: 0.19, green: 0.20, blue: 0.24)

    var body: some View {
        VStack(spacing: 8) {
            switch store.phase {
            case .needsSetup: setup(error: nil)
            case .failed(let message): store.isConnected ? AnyView(failure(message)) : AnyView(setup(error: message))
            case .loading where store.tasks.isEmpty: centered { ProgressView().controlSize(.small); Text(L("Загружаю…", "Loading…")).foregroundStyle(.white.opacity(0.6)) }
            default: store.current != nil ? AnyView(taskPage) : AnyView(content)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 6)
        .onAppear { store.open() }
    }

    // MARK: - Подключение

    private func setup(error: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checklist").font(.system(size: 24)).foregroundStyle(coral)
            Text(L("Подключите Asana", "Connect Asana")).font(.system(size: 14, weight: .semibold))
            Text(L("Нужен персональный токен доступа Asana. Приложение только читает ваши задачи и ничего не меняет. Токен хранится в связке ключей macOS.",
                   "A personal access token from Asana is needed. The app only reads your tasks and changes nothing. The token is stored in the macOS Keychain."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 420)
            SecureField(L("Токен доступа Asana", "Asana access token"), text: $store.tokenText).textFieldStyle(.plain).padding(9).font(.system(size: 12)).frame(width: 340)
                .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
                .onSubmit { store.connect() }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                Button { NSWorkspace.shared.open(AsanaStore.tokenPageURL) } label: { pill(L("Создать токен", "Create token"), fill: Color.white.opacity(0.1)) }.buttonStyle(.plain)
                Button { store.connect() } label: { pill(L("Подключить", "Connect"), fill: purple) }.buttonStyle(.plain)
                    .disabled(store.tokenText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ title: String, fill: Color) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 9).fill(fill))
    }

    private func failure(_ message: String) -> some View {
        centered {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).multilineTextAlignment(.center).frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button { store.refresh() } label: { pill(L("Повторить", "Retry"), fill: purple) }.buttonStyle(.plain)
                Button { store.disconnect() } label: { pill(L("Сменить токен", "Change token"), fill: Color.white.opacity(0.1)) }.buttonStyle(.plain)
            }
        }
    }

    private func centered<C: View>(@ViewBuilder _ body: () -> C) -> some View {
        VStack(spacing: 10) { body() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Страница задачи (переход по подзадаче, родителю, зависимости)

    private var taskPage: some View {
        let link = store.current!
        let state = store.details[link.id] ?? .loading
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { store.back() } label: {
                    Label(store.path.count > 1 ? (store.path[store.path.count - 2].name) : L("К списку", "Back to list"), systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
                }.buttonStyle(.plain).frame(maxWidth: 320, alignment: .leading)
                if store.path.count > 1 {
                    Button { store.backToList() } label: { Image(systemName: "list.bullet").font(.system(size: 11)).frame(width: 28, height: 26)
                        .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line))) }
                        .buttonStyle(.plain).help(L("Вернуться к списку", "Back to the list"))
                }
                Spacer()
                if let url = link.url ?? { if case .loaded(let d) = state { return d.permalink } else { return nil } }() {
                    Button { NSWorkspace.shared.open(url) } label: { Label(L("Открыть в Asana", "Open in Asana"), systemImage: "arrow.up.right.square").font(.system(size: 11, weight: .semibold)).foregroundStyle(coral) }.buttonStyle(.plain)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(pageTitle(link, state)).font(.system(size: 15, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    switch state {
                    case .loading: HStack { ProgressView().controlSize(.small); Text(L("Загружаю…", "Loading…")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                    case .failed(let message): Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                    case .loaded(let detail):
                        pageMeta(detail)
                        loaded(link.id, detail)
                    }
                }.padding(.horizontal, 4).padding(.bottom, 8)
            }
        }
    }

    private func pageTitle(_ link: AsanaLink, _ state: AsanaStore.DetailState) -> String {
        if case .loaded(let d) = state, !d.name.isEmpty { return d.name }
        return link.name
    }

    /// Статус, исполнитель, срок и состояние выполнения под заголовком страницы.
    private func pageMeta(_ d: AsanaTaskDetail) -> some View {
        HStack(spacing: 8) {
            if d.completed { Label(L("Выполнена", "Completed"), systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green) }
            if let status = d.status {
                HStack(spacing: 5) { Circle().fill(statusColor(status)).frame(width: 6, height: 6); Text(status).font(.system(size: 10.5)) }
                    .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
            }
            if let who = d.assignee { Label(who, systemImage: "person").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.6)) }
            if let due = d.dueOn { dueBadge(due) }
            if let project = d.project { Label(project, systemImage: "folder").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4)) }
        }
    }

    // MARK: - Список

    private var content: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Asana").font(.system(size: 13, weight: .semibold))
                if let name = store.userName { Text(name).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                Text("\(store.tasks.count)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                Spacer()
                Label("\(store.doneToday)", systemImage: "checkmark.circle.fill").font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Color.green).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.16)))
                    .help(L("Выполнено мной сегодня", "Completed by me today"))
                if store.phase == .loading { ProgressView().controlSize(.small) }
                else if let date = store.updatedAt { Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)) }
                iconButton("arrow.clockwise", help: L("Обновить", "Refresh")) { store.refresh() }
                iconButton("rectangle.portrait.and.arrow.right", help: L("Отключить Asana", "Disconnect Asana")) { store.disconnect() }
            }
            filterBar
            if store.visibleStatuses.isEmpty {
                centered { Text(store.tasks.isEmpty ? L("Нет незавершённых задач", "No open tasks") : L("Все статусы скрыты фильтром", "All statuses are hidden by the filter"))
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)) }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.visibleStatuses, id: \.self) { status in section(status) }
                    }.padding(.horizontal, 2).padding(.bottom, 6)
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
        }.buttonStyle(.plain).help(help)
    }

    @State private var showFilter = false

    /// Фильтр по статусам: кнопка открывает список с галочками (галочка — колонка показана) и кнопками «Выбрать все» / «Снять все».
    private var filterBar: some View {
        let all = store.statuses
        let shown = all.filter { !store.hiddenStatuses.contains($0) }.count
        return HStack(spacing: 8) {
            Button { showFilter.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle\(shown < all.count ? ".fill" : "")").font(.system(size: 12))
                    Text(L("Статусы", "Statuses")).font(.system(size: 11.5, weight: .medium))
                    Text("\(shown)/\(all.count)").font(.system(size: 10, weight: .bold)).opacity(0.65)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(shown < all.count ? coral.opacity(0.7) : line)))
            }.buttonStyle(.plain)
            .popover(isPresented: $showFilter, arrowEdge: .bottom) { filterList(all) }
            Spacer()
        }
    }

    private func filterList(_ all: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button { store.hiddenStatuses = [] } label: { filterAction(L("Выбрать все", "Select all")) }.buttonStyle(.plain)
                Button { store.hiddenStatuses = Set(all) } label: { filterAction(L("Снять все", "Clear all")) }.buttonStyle(.plain)
            }.padding(10)
            Divider().overlay(line)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(all, id: \.self) { status in
                        let on = !store.hiddenStatuses.contains(status)
                        Button { store.toggle(status) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14)).foregroundStyle(on ? coral : Color.white.opacity(0.4))
                                Circle().fill(statusColor(status)).frame(width: 7, height: 7)
                                Text(status == AsanaClient.noStatus ? L("Без статуса", "No status") : status).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 10)
                                Text("\(store.count(for: status))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 4)
            }
            .frame(maxHeight: 320)
        }
        .frame(width: 270)
        .background(Color(red: 0.09, green: 0.10, blue: 0.12))
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func filterAction(_ title: String) -> some View {
        Text(title).font(.system(size: 11.5, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.1)))
    }

    /// Цвет статуса по названию колонки; незнакомым — нейтральный.
    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "backlog", "to do": return Color(red: 0.62, green: 0.65, blue: 0.72)
        case "ready to dev": return Color(red: 0.36, green: 0.58, blue: 1.0)
        case "in progress": return Color(red: 0.98, green: 0.72, blue: 0.2)
        case "code review": return Color(red: 0.62, green: 0.48, blue: 0.95)
        case "ready to stage": return Color(red: 0.25, green: 0.78, blue: 0.62)
        case "on hold": return Color(red: 0.93, green: 0.36, blue: 0.36)
        default: return Color(red: 0.5, green: 0.55, blue: 0.62)
        }
    }

    @ViewBuilder private func section(_ status: String) -> some View {
        let items = store.tasks(in: status)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(statusColor(status)).frame(width: 7, height: 7)
                Text((status == AsanaClient.noStatus ? L("Без статуса", "No status") : status).uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Text("\(items.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
            }
            ForEach(items) { task in row(task) }
        }
    }

    // MARK: - Строка и раскрытие

    private func row(_ task: AsanaTask) -> some View {
        let open = store.expanded.contains(task.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { store.toggleExpanded(task.id) } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.white.opacity(0.4)).frame(width: 10)
                    typeIcon(task.taskType)
                    Text(task.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let parent = task.parentName {
                        Label(parent, systemImage: "arrow.turn.down.right").font(.system(size: 10)).lineLimit(1).foregroundStyle(.white.opacity(0.4))
                            .help(L("Подзадача: ", "Subtask of: ") + parent)
                    }
                    Spacer(minLength: 8)
                    if task.subtaskCount > 0 { Label("\(task.subtaskCount)", systemImage: "list.bullet.indent").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)) }
                    if let key = task.ftpKey { Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(red: 0.62, green: 0.74, blue: 1.0)) }
                    if let priority = task.priority { priorityBadge(priority) }
                    if let due = task.dueOn { dueBadge(due) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { detailView(task).padding(.horizontal, 12).padding(.bottom, 10).transition(.opacity) }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
    }

    @ViewBuilder private func typeIcon(_ type: String?) -> some View {
        switch type {
        case "Баг": Image(systemName: "ladybug.fill").font(.system(size: 10)).foregroundStyle(Color(red: 0.93, green: 0.36, blue: 0.36)).help(type ?? "")
        case "Технический долг": Image(systemName: "wrench.and.screwdriver.fill").font(.system(size: 10)).foregroundStyle(Color(red: 0.98, green: 0.72, blue: 0.2)).help(type ?? "")
        default: Image(systemName: "checkmark.square").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).help(type ?? L("Задача", "Task"))
        }
    }

    private func priorityBadge(_ priority: String) -> some View {
        let color: Color = priority.hasPrefix("Высок") ? .red : priority.hasPrefix("Средн") ? .orange : priority.hasPrefix("Низк") ? Color(red: 0.36, green: 0.58, blue: 1.0) : .gray
        return HStack(spacing: 3) { Image(systemName: "flag.fill").font(.system(size: 8)); Text(priority).font(.system(size: 10)) }.foregroundStyle(color)
    }

    private func dueBadge(_ due: String) -> some View {
        let overdue = (AsanaStore.dueDate(due).map { $0 < Calendar.current.startOfDay(for: Date()) }) ?? false
        return HStack(spacing: 3) { Image(systemName: "calendar").font(.system(size: 9)); Text(AsanaStore.dueText(due)).font(.system(size: 10)) }
            .foregroundStyle(overdue ? Color.red : Color.white.opacity(0.5)).help(due)
    }

    @ViewBuilder private func detailView(_ task: AsanaTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(line)
            switch store.details[task.id] ?? .loading {
            case .loading: HStack { ProgressView().controlSize(.small); Text(L("Загружаю подробности…", "Loading details…")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
            case .failed(let message): Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            case .loaded(let detail): loaded(task.id, detail)
            }
            HStack {
                if let project = task.project { Label(project, systemImage: "folder").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                Spacer()
                Button { store.open(task) } label: { Label(L("Открыть страницей", "Open full page"), systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7)) }.buttonStyle(.plain)
                if let url = task.permalink {
                    Button { NSWorkspace.shared.open(url) } label: { Label(L("Открыть в Asana", "Open in Asana"), systemImage: "arrow.up.right.square").font(.system(size: 11, weight: .semibold)).foregroundStyle(coral) }.buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private func loaded(_ taskID: String, _ detail: AsanaTaskDetail) -> some View {
        if !detail.fields.isEmpty || !detail.tags.isEmpty {
            FlowChips(items: detail.fields.map { "\($0.name): \($0.value)" } + detail.tags.map { "#\($0)" })
        }
        if let by = detail.createdBy {
            Text(L("Создал(а) \(by)", "Created by \(by)") + (detail.createdAt.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }
        block(L("Описание", "Description")) {
            if detail.notes.isEmpty { Text(L("Нет описания", "No description")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35)) }
            else { Text(detail.notes).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
        }
        if !detail.subtasks.isEmpty {
            block(L("Подзадачи", "Subtasks") + " \(detail.subtasks.filter(\.completed).count)/\(detail.subtasks.count)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detail.subtasks) { sub in
                        Button { store.open(sub) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: sub.completed ? "checkmark.circle.fill" : "circle").font(.system(size: 11)).foregroundStyle(sub.completed ? Color.green : Color.white.opacity(0.4))
                                Text(sub.name).font(.system(size: 11.5)).strikethrough(sub.completed).foregroundStyle(sub.completed ? Color.white.opacity(0.4) : Color.white)
                                if let who = sub.assignee { Text(who).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)) }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L("Открыть подзадачу", "Open the subtask"))
                    }
                }
            }
        }
        if detail.parent != nil || !detail.blockedBy.isEmpty || !detail.blocking.isEmpty {
            block(L("Связи", "Relations")) {
                VStack(alignment: .leading, spacing: 4) {
                    if let parent = detail.parent { linkRow(L("Подзадача задачи", "Subtask of"), "arrow.turn.up.left", parent) }
                    ForEach(detail.blockedBy) { linkRow(L("Ждёт завершения", "Blocked by"), "lock.fill", $0) }
                    ForEach(detail.blocking) { linkRow(L("Блокирует", "Blocking"), "hourglass", $0) }
                }
            }
        }
        if !detail.attachments.isEmpty {
            block(L("Вложения", "Attachments") + " \(detail.attachments.count)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detail.attachments) { file in
                        Button { if let url = file.url { NSWorkspace.shared.open(url) } } label: {
                            HStack(spacing: 7) {
                                Image(systemName: file.iconName).font(.system(size: 12)).foregroundStyle(coral).frame(width: 16)
                                Text(file.name).font(.system(size: 11.5)).lineLimit(1)
                                if let size = file.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                                else if file.host != "asana" { Text(file.host).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
                                Spacer(minLength: 6)
                                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05))).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(L("Открыть в Asana", "Open in Asana"))
                    }
                }
            }
        }
        block(L("Комментарии", "Comments") + " \(detail.comments.count)") {
            if detail.comments.isEmpty { Text(L("Нет комментариев", "No comments")).font(.system(size: 11)).foregroundStyle(.white.opacity(0.35)) }
            else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detail.comments) { comment in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(comment.author).font(.system(size: 11, weight: .semibold))
                                if let date = comment.createdAt { Text(date.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)) }
                            }
                            if !comment.text.isEmpty { Text(comment.text).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            if !comment.attachments.isEmpty { commentFiles(comment.attachments) }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    }
                }
            }
        }
        CommentComposer(store: store, taskID: taskID, field: field, line: line, purple: purple)
    }

    /// Файлы внутри комментария: картинки миниатюрами, остальное строками; клик открывает вложение в Asana.
    private func commentFiles(_ files: [AsanaAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(files) { file in
                Button { if let url = file.url { NSWorkspace.shared.open(url) } } label: {
                    HStack(spacing: 8) {
                        if file.isImage, let url = file.downloadURL {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().aspectRatio(contentMode: .fill) }
                                else { Image(systemName: file.iconName).foregroundStyle(coral) }
                            }
                            .frame(width: 44, height: 34).clipShape(RoundedRectangle(cornerRadius: 5))
                        } else {
                            Image(systemName: file.iconName).font(.system(size: 13)).foregroundStyle(coral).frame(width: 44, height: 34)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.06)))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            if let size = file.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)) }
                        }
                        Spacer(minLength: 6)
                        Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(5).background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.05))).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("Открыть вложение в Asana", "Open the attachment in Asana"))
            }
        }
    }

    /// Связанная задача: подпись связи, название и переход в Asana.
    private func linkRow(_ relation: String, _ symbol: String, _ link: AsanaLink) -> some View {
        Button { store.open(link) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).frame(width: 14)
                Text(relation).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Text(link.name).font(.system(size: 11.5)).strikethrough(link.completed).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.3))
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help(L("Открыть задачу", "Open the task"))
    }

    private func block<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.4))
            body()
        }
    }
}

/// Плашки, переносящиеся на следующую строку.
private struct FlowChips: View {
    let items: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 5, alignment: .leading)], alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                Text(item).font(.system(size: 10)).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
        }
    }
}


/// Поле нового комментария: Enter отправляет, Shift+Enter переносит строку; скрепка, перетаскивание и вставка из буфера
/// добавляют файлы. Выбранные файлы видны над полем и убираются крестиком до отправки.
private struct CommentComposer: View {
    @ObservedObject var store: AsanaStore
    let taskID: String
    let field: Color, line: Color, purple: Color
    @State private var text = ""
    @State private var files: [URL] = []
    @State private var dropTargeted = false
    @FocusState private var focused: Bool

    /// Копии выбранных файлов: так вложение не пропадёт, если исходник (скриншот на рабочем столе) переименуют или удалят.
    private static let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("omnimac-asana-attachments")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(files, id: \.self) { chip($0) } }.padding(.top, 6).padding(.trailing, 6)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button(action: pick) {
                    Image(systemName: "paperclip").font(.system(size: 13)).frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                }.buttonStyle(.plain).help(L("Прикрепить файл (можно также перетащить или вставить из буфера)", "Attach a file (you can also drop or paste it)")).disabled(store.sending.contains(taskID))
                TextField(L("Написать комментарий…  (Enter — отправить, Shift+Enter — новая строка)", "Write a comment…  (Enter to send, Shift+Enter for a new line)"), text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).lineLimit(1...6).padding(8).focused($focused)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)).overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? purple : line)))
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { text += "\n"; return .handled }
                        send(); return .handled
                    }
                Button(action: send) {
                    Group {
                        if store.sending.contains(taskID) { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)) }
                    }
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8).fill(purple.opacity(canSend ? 1 : 0.35)))
                }.buttonStyle(.plain).disabled(!canSend).help(L("Отправить в Asana", "Send to Asana"))
            }
            if let error = store.commentError[taskID] { Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { add([url]) }
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: EditingShortcuts.pasteAttachmentsNotification)) { note in
            guard focused, let urls = note.userInfo?["urls"] as? [URL] else { return }
            (note.userInfo?["taken"] as? () -> Void)?()
            add(urls)
        }
    }

    private func chip(_ url: URL) -> some View {
        HStack(spacing: 7) {
            if let image = NSImage(contentsOf: url), ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains(url.pathExtension.lowercased()) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "doc").font(.system(size: 14)).frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(.system(size: 10.5, weight: .medium)).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                Text(Self.sizeText(url)).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08)))
        .overlay(alignment: .topTrailing) {
            Button { remove(url) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white, Color.black.opacity(0.8)) }
                .buttonStyle(.plain).offset(x: 6, y: -6).help(L("Убрать файл", "Remove the file")).disabled(store.sending.contains(taskID))
        }
    }

    private static func sizeText(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private var canSend: Bool {
        !(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty) && !store.sending.contains(taskID)
    }

    /// Копирует выбранные файлы в рабочую папку. Если macOS не даёт читать файл (например, с рабочего стола), причина видна сразу.
    private func add(_ urls: [URL]) {
        store.commentError[taskID] = nil
        for url in urls {
            let name = url.lastPathComponent
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                store.commentError[taskID] = L("\(name): файл не найден или нет доступа. Разрешите OmniMac доступ к папке в Настройках macOS → Конфиденциальность.",
                                              "\(name): the file was not found or access was denied. Allow OmniMac access to the folder in macOS Settings → Privacy."); continue
            }
            if isDirectory.boolValue { store.commentError[taskID] = L("\(name): папки прикреплять нельзя", "\(name): folders cannot be attached"); continue }
            let folder = Self.stagingRoot.appendingPathComponent(UUID().uuidString)
            let target = folder.appendingPathComponent(name)
            do {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > AsanaClient.maxAttachmentBytes { store.commentError[taskID] = L("\(name): больше 100 МБ", "\(name): larger than 100 MB"); continue }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
                files.append(target)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                store.commentError[taskID] = L("\(name): не удалось прочитать файл (\(error.localizedDescription)). Проверьте доступ OmniMac к этой папке в Настройках macOS.",
                                              "\(name): could not read the file (\(error.localizedDescription)). Check OmniMac's access to this folder in macOS Settings.")
            }
        }
    }

    private static func isStaged(_ url: URL) -> Bool { url.path.hasPrefix(stagingRoot.path) }

    private func remove(_ url: URL) {
        files.removeAll { $0 == url }
        if Self.isStaged(url) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    /// Диалог выбора файлов. Панель notch стоит выше обычных окон, поэтому диалог поднимается ещё выше и забирает фокус.
    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK { add(panel.urls) }
        }
    }

    private func send() {
        guard canSend else { return }
        let value = text, pending = files
        store.send(taskID: taskID, text: value, files: pending) { failed in
            guard let failed else { return }          // текст не ушёл: ничего не трогаем
            text = ""
            // Отправленные файлы больше не нужны; не загрузившиеся остаются для повтора.
            for url in pending where !failed.contains(url) && Self.isStaged(url) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            files = failed
        }
    }
}
