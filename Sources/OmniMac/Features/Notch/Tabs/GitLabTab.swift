import SwiftUI

/// Вкладка GitLab: мои МР — открытые, смерженные и закрытые за последние дни. Только чтение.
struct GitLabTab: View {
    @ObservedObject var store: GitLabStore

    private let purple = Color(red: 0.50, green: 0.35, blue: 0.84)
    private let field = Color(red: 0.08, green: 0.09, blue: 0.11)
    private let line = Color(red: 0.19, green: 0.20, blue: 0.24)
    private let orange = Color(red: 0.99, green: 0.43, blue: 0.14)

    var body: some View {
        VStack(spacing: 8) {
            switch store.phase {
            case .needsSetup: setup(error: nil)
            case .failed(let message): store.isConnected ? AnyView(failure(message)) : AnyView(setup(error: message))
            case .loading where store.requests.isEmpty: centered { ProgressView().controlSize(.small); Text(L("Загружаю…", "Loading…")).foregroundStyle(.white.opacity(0.6)) }
            default: list
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
            GitLabLogoView(lineWidth: 2).frame(width: 30, height: 30).foregroundStyle(orange)
            Text(L("Подключите GitLab", "Connect GitLab")).font(.system(size: 14, weight: .semibold))
            Text(L("Нужен персональный токен только со scope read_api: приложение лишь читает и ничего не меняет. Токен хранится в связке ключей macOS.",
                   "A personal access token with only the read_api scope is needed: the app just reads and changes nothing. The token is stored in the macOS Keychain."))
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).multilineTextAlignment(.center).frame(maxWidth: 420)
            VStack(spacing: 8) {
                TextField("https://gitlab.com", text: $store.hostText).textFieldStyle(.plain).padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
                SecureField(L("Токен доступа (glpat-…)", "Access token (glpat-…)"), text: $store.tokenText).textFieldStyle(.plain).padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
                    .onSubmit { store.connect() }
            }.font(.system(size: 12)).frame(width: 340)
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack(spacing: 10) {
                Button { if let url = store.tokenPageURL { NSWorkspace.shared.open(url) } } label: { pill(L("Создать токен", "Create token"), fill: Color.white.opacity(0.1)) }.buttonStyle(.plain)
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

    // MARK: - Список

    private var list: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                sectionPicker
                if let user = store.username { Text("@\(user)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)) }
                Spacer()
                if store.phase == .loading { ProgressView().controlSize(.small) }
                else if let date = store.updatedAt { Text(date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)) }
                iconButton("arrow.clockwise", help: L("Обновить", "Refresh")) { store.refresh() }
                iconButton("rectangle.portrait.and.arrow.right", help: L("Отключить GitLab", "Disconnect GitLab")) { store.disconnect() }
            }
            if store.section == .mine { mineList } else { reviewList }
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 2) {
            ForEach([GitLabStore.Section.mine, .review], id: \.rawValue) { section in
                let selected = store.section == section
                Button { store.section = section } label: {
                    HStack(spacing: 6) {
                        Text(section == .mine ? "My merge requests" : L("На ревью", "For review")).font(.system(size: 12, weight: .medium))
                        let badge = section == .mine ? store.requests.count : store.reviewsWaiting
                        if badge > 0 {
                            Text("\(badge)").font(.system(size: 10, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(section == .review ? orange.opacity(0.85) : Color.white.opacity(0.18)))
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.14) : .clear))
                }.buttonStyle(.plain)
            }
        }.padding(3).background(RoundedRectangle(cornerRadius: 11).fill(field))
    }

    private var mineList: some View {
        Group {
            if store.requests.isEmpty {
                centered { Text(L("Нет МР за последние \(GitLabStore.days) дня", "No merge requests in the last \(GitLabStore.days) days")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)) }
            } else {
                // Один хронологический список: самое свежее событие (слияние, закрытие, правка) сверху.
                let groups = GitLabStore.orderedGroups(store.requests) { $0.state == .opened }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups.active) { branchGroup($0, review: false) }
                        // Ветки, где все МР смержены или закрыты, лежат ниже и притемнены.
                        ForEach(groups.finished) { branchGroup($0, review: false).opacity(0.6) }
                    }.padding(.horizontal, 2).padding(.bottom, 6)
                }
            }
        }
    }

    private var reviewList: some View {
        Group {
            if store.reviews.isEmpty {
                centered { Text(L("Нет МР на ревью и проверенных за последние \(GitLabStore.days) дня", "No merge requests to review or reviewed in the last \(GitLabStore.days) days")).font(.system(size: 12)).foregroundStyle(.white.opacity(0.4)) }
            } else {
                // Ветка остаётся наверху, пока в ней есть хоть один МР, требующий моего внимания; ниже — ветки, где всё проверено или завершено.
                let groups = GitLabStore.orderedGroups(store.reviews) { !$0.isDoneForMe }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(groups.active) { branchGroup($0, review: true) }
                        if !groups.finished.isEmpty {
                            HStack(spacing: 8) {
                                Rectangle().fill(line).frame(height: 1)
                                Text(L("Проверено", "Reviewed").uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.35))
                                Rectangle().fill(line).frame(height: 1)
                            }.padding(.vertical, 4)
                            ForEach(groups.finished) { branchGroup($0, review: true).opacity(0.5) }
                        }
                    }.padding(.horizontal, 2).padding(.bottom, 6)
                }
            }
        }
    }

    /// Заголовок группы — исходная ветка и репозитории, в которые она идёт; под ним МР этой ветки.
    private func branchGroup(_ group: GitLabBranchGroup, review: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(red: 0.62, green: 0.74, blue: 1.0))
                Text(group.branch).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Color(red: 0.62, green: 0.74, blue: 1.0)).lineLimit(1)
                Text("\(group.items.count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                Spacer(minLength: 6)
            }
            ForEach(group.items) { row($0, review: review) }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(field).overlay(RoundedRectangle(cornerRadius: 8).stroke(line)))
        }.buttonStyle(.plain).help(help)
    }

    private func color(_ state: GitLabMergeRequest.State) -> Color {
        switch state {
        case .opened: return Color(red: 0.25, green: 0.78, blue: 0.45)
        case .merged: return Color(red: 0.36, green: 0.58, blue: 1.0)
        case .closed: return Color(red: 0.93, green: 0.36, blue: 0.36)
        }
    }

    private func statusTitle(_ state: GitLabMergeRequest.State) -> String {
        switch state {
        case .opened: return "Open"
        case .merged: return "Merged"
        case .closed: return "Closed"
        }
    }

    private func statusSymbol(_ state: GitLabMergeRequest.State) -> String {
        switch state {
        case .opened: return "arrow.triangle.pull"
        case .merged: return "arrow.triangle.merge"
        case .closed: return "xmark"
        }
    }

    /// Как плашка статуса в GitLab: тонированная капсула со значком и подписью.
    private func statusPill(_ state: GitLabMergeRequest.State) -> some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol(state)).font(.system(size: 9, weight: .bold))
            Text(statusTitle(state)).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color(state))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color(state).opacity(0.16)).overlay(Capsule().stroke(color(state).opacity(0.45))))
    }

    /// Репозиторий МР; полный путь «группа/проект» во всплывающей подсказке.
    private func repositoryChip(_ mr: GitLabMergeRequest) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "shippingbox").font(.system(size: 9))
            Text(mr.projectName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
        .help(mr.projectPath)
    }

    private func branchChip(_ name: String) -> some View {
        Text(name).font(.system(size: 10.5, design: .monospaced)).lineLimit(1)
            .foregroundStyle(Color(red: 0.62, green: 0.74, blue: 1.0))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(red: 0.62, green: 0.74, blue: 1.0).opacity(0.12)))
    }

    private func eventText(_ mr: GitLabMergeRequest) -> String {
        let date = mr.finishedAt ?? mr.updatedAt
        let when = date.formatted(.relative(presentation: .named))
        switch mr.state {
        case .opened: return L("обновлён \(when)", "updated \(when)")
        case .merged: return L("смержен \(when)", "merged \(when)")
        case .closed: return L("закрыт \(when)", "closed \(when)")
        }
    }

    private func row(_ mr: GitLabMergeRequest, review: Bool = false) -> some View {
        Button { NSWorkspace.shared.open(mr.webURL) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    if mr.isDraft { Text("Draft").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.14))) }
                    Text(mr.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    metrics(mr, review: review)
                }
                HStack(spacing: 6) {
                    statusPill(mr.state)
                    Text(mr.author).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                    Text(L("хочет влить", "requested to merge")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    Text(L("в", "into")).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5))
                    branchChip(mr.targetBranch)
                    repositoryChip(mr)
                    Spacer(minLength: 8)
                    Text(eventText(mr)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(field).overlay(RoundedRectangle(cornerRadius: 9).stroke(line)))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help("\(mr.reference)\n" + L("Открыть в браузере", "Open in browser"))
    }

    /// Лайки, комментарии, решённые ветки, конфликты и pipeline — значки как в GitLab/SF Symbols.
    private let reviewBlue = Color(red: 0.36, green: 0.58, blue: 1.0)

    /// В «Моих МР» — общая картина (лайки, комментарии, апрувы, pipeline). В «На ревью» только моё:
    /// стоит ли мой лайк и апрув, сколько моих комментариев и сколько из них решено.
    private func metrics(_ mr: GitLabMergeRequest, review: Bool = false) -> some View {
        HStack(spacing: 9) {
            if mr.hasConflicts { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(L("Есть конфликты", "Has conflicts")) }
            if review {
                if mr.needsRecheck {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(orange)
                        .help(L("После вашей проверки появились новые коммиты", "New commits since your review"))
                }
                Image(systemName: mr.myLikeAt != nil ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(mr.myLikeAt != nil ? reviewBlue : Color.white.opacity(0.25))
                    .help(mr.myLikeAt != nil ? L("Ваш лайк стоит", "You liked this") : L("Вы не ставили лайк", "You have not liked this"))
                Image(systemName: mr.iApproved ? "checkmark.seal.fill" : "checkmark.seal")
                    .foregroundStyle(mr.iApproved ? reviewBlue : Color.white.opacity(0.25))
                    .help(mr.iApproved ? L("Ваш апрув стоит", "You approved this") : L("Вы не ставили апрув", "You have not approved this"))
                if let mine = mr.myComments, mine > 0 {
                    let resolved = mr.myResolvedComments ?? 0
                    HStack(spacing: 3) { Image(systemName: "checkmark.bubble"); Text("\(resolved)/\(mine)") }
                        .foregroundStyle(resolved == mine ? Color.green : Color.white.opacity(0.6))
                        .help(L("Ваши комментарии: \(mine), решено: \(resolved)", "Your comments: \(mine), resolved: \(resolved)"))
                } else {
                    Image(systemName: "bubble.left").foregroundStyle(Color.white.opacity(0.25)).help(L("У вас нет комментариев", "You have no comments"))
                }
            } else {
                metric("hand.thumbsup", mr.upvotes, help: L("Лайки", "Upvotes"), tint: mr.upvotes > 0 ? Color.green : nil)
                if mr.downvotes > 0 { metric("hand.thumbsdown", mr.downvotes, help: L("Дизлайки", "Downvotes"), tint: .red) }
                metric("bubble.left", mr.commentCount, help: L("Комментарии", "Comments"), tint: nil)
                if let total = mr.totalThreads, total > 0, let resolved = mr.resolvedThreads {
                    HStack(spacing: 3) { Image(systemName: "checkmark.bubble"); Text("\(resolved)/\(total)") }
                        .foregroundStyle(resolved == total ? Color.green : Color.white.opacity(0.55))
                        .help(L("Решённые обсуждения: \(resolved) из \(total)", "Resolved threads: \(resolved) of \(total)"))
                }
                if mr.state == .opened, let approved = mr.approvals {
                    let needed = mr.approvalsRequired
                    let done = approved > 0 && (needed == nil || approved >= needed!)
                    HStack(spacing: 3) {
                        Image(systemName: done ? "checkmark.seal.fill" : "checkmark.seal")
                        Text(needed.map { "\(approved)/\($0)" } ?? "\(approved)")
                    }
                    .foregroundStyle(done ? Color.green : Color.white.opacity(approved > 0 ? 0.7 : 0.25))
                    .help(needed.map { L("Апрувы: \(approved) из \($0)", "Approvals: \(approved) of \($0)") } ?? L("Апрувы: \(approved)", "Approvals: \(approved)"))
                }
            }
            if let status = mr.pipelineStatus { pipelineBadge(status, url: mr.pipelineURL) }
        }.font(.system(size: 10.5))
    }

    private func metric(_ symbol: String, _ value: Int, help: String, tint: Color?) -> some View {
        HStack(spacing: 3) { Image(systemName: symbol); Text("\(value)") }
            .foregroundStyle(tint ?? Color.white.opacity(value > 0 ? 0.55 : 0.25)).help(help)
    }

    private func pipelineBadge(_ status: String, url: URL?) -> some View {
        let info = Self.pipelineInfo(status)
        return HStack(spacing: 3) { Image(systemName: info.symbol); Text(info.title) }
            .foregroundStyle(info.color)
            .help("Pipeline: \(info.title)")
            .onTapGesture { if let url { NSWorkspace.shared.open(url) } }
    }

    static func pipelineInfo(_ status: String) -> (symbol: String, title: String, color: Color) {
        switch status {
        case "success": return ("checkmark.circle.fill", "Passed", .green)
        case "failed": return ("xmark.circle.fill", "Failed", .red)
        case "running": return ("play.circle.fill", "Running", .blue)
        case "pending", "created", "waiting_for_resource", "preparing", "scheduled": return ("clock.fill", "Pending", .yellow)
        case "canceled", "canceling": return ("slash.circle.fill", "Canceled", .gray)
        case "skipped": return ("forward.circle.fill", "Skipped", .gray)
        case "manual": return ("hand.tap.fill", "Manual", .orange)
        case "success_with_warnings": return ("exclamationmark.circle.fill", "Warnings", .orange)
        default: return ("circle.dashed", status.capitalized, .gray)
        }
    }
}
