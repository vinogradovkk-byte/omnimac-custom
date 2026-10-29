import AppKit
import SwiftUI

/// Capturas de las pestañas de trabajo (AI, GitLab, Asana, Notas) con datos inventados: nada de cuentas ni tareas reales.
extension Snapshots {
    private static let size = CGSize(width: 760, height: 520)

    static func renderWorkTabs(into dir: URL, completion: @escaping () -> Void) {
        let notchSize = CGSize(width: 185, height: 32)
        let model = NotchModel(hasNotch: true, notchSize: notchSize, expandedSize: size)
        model.expanded = true; model.blackVisible = true; model.showContent = true

        let ai = AIChatCoordinator(); ai.isSample = true
        let gitlab = GitLabStore(), asana = AsanaStore()
        let notes = NotesStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("omnimac-snapshot-work-notes.json"))
        let manager = FeatureManager.shared
        let view = NotchView(model: model, media: MediaBridge(), battery: BatteryMonitor(), keepAwake: manager.keepAwake,
                             calendar: CalendarBridge(), sound: manager.sound, stats: SystemStats(), vscode: VSCodeWindowMonitor(),
                             ai: ai, gitlab: gitlab, asana: asana, notes: notes, mail: MailLauncher(), vpn: VPNMonitor())
        let margin: CGFloat = 36
        let hosting = NSHostingView(rootView: view)
        let window = offscreenWindow(size: CGSize(width: size.width + margin * 2, height: size.height + margin), content: hosting)

        sampleAI(ai); sampleGitLab(gitlab, section: .mine); sampleAsana(asana, expanded: true); sampleNotes(notes)
        let steps: [(NotchTab, String, () -> Void)] = [
            (.ai, "work-ai", {}),
            (.gitlab, "work-gitlab-mine", {}),
            (.gitlab, "work-gitlab-review", { sampleGitLab(gitlab, section: .review) }),
            (.asana, "work-asana", {}),
            (.notes, "work-notes", {}),
        ]
        var pending = steps
        func next() {
            guard let (tab, name, prepare) = pending.first else { window.orderOut(nil); completion(); return }
            pending.removeFirst()
            prepare()
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { model.tab = tab }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                save(hosting, to: dir.appendingPathComponent("\(name).png")); next()
            }
        }
        next()
    }

    // MARK: - Datos de muestra

    private static func ago(_ hours: Double) -> Date { Date().addingTimeInterval(-hours * 3600) }

    private static func sampleAI(_ ai: AIChatCoordinator) {
        let efforts = ["low", "medium", "high"]
        ai.selectedProvider = .claude
        ai.states = [.codex: .ready, .claude: .ready]
        ai.models[.claude] = [AIModel(id: "sonnet", name: "Sonnet", efforts: efforts, defaultEffort: "medium", detail: "Fast, balanced"),
                              AIModel(id: "opus", name: "Opus", efforts: efforts, defaultEffort: "medium", detail: "Most capable")]
        ai.selectedModels[.claude] = "sonnet"; ai.selectedEfforts[.claude] = "medium"
        ai.usages[.claude] = AIUsage(windows: [AIUsageWindow(title: L("Сессия · 5 ч", "Session · 5 h"), remainingPercent: 78, resetsAt: Date().addingTimeInterval(3 * 3600)),
                                               AIUsageWindow(title: L("Неделя", "Week"), remainingPercent: 41, resetsAt: Date().addingTimeInterval(3 * 86400))])
        ai.conversations[.claude] = [AIConversationSummary(id: "1", provider: .claude, title: "Regex for ISO dates", root: nil, updatedAt: ago(2), model: "sonnet")]
        ai.messages[.claude] = [
            AIMessage(role: .user, text: L("Как в Swift отсортировать массив структур по двум полям?", "How do I sort an array of structs by two fields in Swift?")),
            AIMessage(role: .assistant, text: L("Сравните поля кортежем: `items.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }`. Кортежи сравниваются слева направо, поэтому имя учитывается, только если приоритеты равны.",
                                                "Compare the fields as tuples: `items.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }`. Tuples compare left to right, so the name only matters when priorities are equal.")),
        ]
    }

    private static func mr(_ iid: Int, _ project: String, _ title: String, _ state: GitLabMergeRequest.State = .opened, branch: String,
                           author: String = "alex.demo", target: String = "main", age: Double = 5, comments: Int = 0, pipeline: String? = "success",
                           up: Int = 0, threads: (Int, Int)? = nil, approvals: (Int, Int)? = nil, finished: Double? = nil,
                           myLike: Double? = nil, myApproval: Double? = nil, lastCommit: Double? = nil, mine: (Int, Int)? = nil) -> GitLabMergeRequest {
        var request = GitLabMergeRequest(
            id: iid * 100 + project.count, iid: iid, projectID: project.count, title: title, state: state,
            webURL: URL(string: "https://gitlab.example.com/\(project)/-/merge_requests/\(iid)")!, reference: "\(project)!\(iid)",
            author: author, isDraft: false, sourceBranch: branch, targetBranch: target, createdAt: ago(age), updatedAt: ago(age / 2),
            finishedAt: finished.map(ago), commentCount: comments, hasConflicts: false, pipelineStatus: pipeline, pipelineURL: nil, upvotes: up, downvotes: 0)
        request.resolvedThreads = threads?.0; request.totalThreads = threads?.1
        request.approvals = approvals?.0; request.approvalsRequired = approvals?.1
        request.myLikeAt = myLike.map(ago); request.iApproved = myApproval != nil; request.myApprovalAt = myApproval.map(ago)
        request.lastCommitAt = lastCommit.map(ago); request.myComments = mine?.0; request.myResolvedComments = mine?.1
        return request
    }

    private static func sampleGitLab(_ store: GitLabStore, section: GitLabStore.Section) {
        let mine = [
            mr(41, "acme/backend", "Add retry to payment webhook", branch: "feature/payment-retry", age: 3, comments: 4, up: 1, threads: (1, 3), approvals: (1, 2)),
            mr(42, "acme/web", "Payment retry: show status in the UI", branch: "feature/payment-retry", target: "develop", age: 2, comments: 1, pipeline: "running", threads: (0, 1), approvals: (0, 2)),
            mr(38, "acme/backend", "Fix pagination in orders list", .merged, branch: "fix/orders-pagination", age: 30, comments: 6, up: 2, finished: 6),
            mr(35, "acme/infra", "Bump Postgres to 16", .closed, branch: "chore/postgres-16", age: 40, pipeline: "failed", finished: 20),
        ]
        let review = [
            mr(57, "acme/backend", "Cache user permissions", branch: "feature/permissions-cache", author: "maria.k", age: 4, comments: 3, threads: (2, 3), mine: (3, 2)),
            mr(58, "acme/web", "Permissions cache: invalidate on logout", branch: "feature/permissions-cache", author: "maria.k", target: "develop", age: 3, pipeline: "running", mine: (0, 0)),
            mr(52, "acme/backend", "Rename order statuses", branch: "refactor/order-statuses", author: "ivan.s", age: 20, up: 1,
               threads: (0, 0), approvals: (1, 1), myLike: 12, myApproval: 12, lastCommit: 3, mine: (1, 1)),
            mr(49, "acme/infra", "Add staging alerts", branch: "chore/staging-alerts", author: "dmitry.p", age: 26, up: 1, approvals: (1, 1), myLike: 18, myApproval: 18, mine: (2, 2)),
            mr(47, "acme/web", "Dark theme for settings", .merged, branch: "feature/dark-settings", author: "olga.v", age: 40, finished: 9),
        ]
        store.useSample(mine: mine, review: review, section: section)
    }

    private static func sampleAsana(_ store: AsanaStore, expanded: Bool) {
        func task(_ id: String, _ name: String, _ status: String, due: String? = nil, subtasks: Int = 0, priority: String? = nil) -> AsanaTask {
            AsanaTask(id: id, name: name, status: status, project: "Mobile app", dueOn: due, permalink: nil, ftpKey: nil, taskType: nil,
                      priority: priority, qa: nil, subtaskCount: subtasks, modifiedAt: ago(3), parentName: nil)
        }
        let tasks = [
            task("1", "Design the onboarding screens", "To do", due: "2026-11-02", priority: "High"),
            task("2", "Write release notes for 2.4", "To do", subtasks: 2),
            task("3", "Fix crash on login with expired token", "In progress", due: "2026-10-30", subtasks: 3, priority: "High"),
            task("4", "Review the pricing page copy", "Review", due: "2026-11-04"),
            task("5", "Smoke test the payment flow", "QA", priority: "Medium"),
        ]
        let detail = AsanaTaskDetail(
            name: "Fix crash on login with expired token", completed: false, assignee: "Alex Demo", dueOn: "2026-10-30", status: "In progress",
            project: "Mobile app", permalink: nil,
            notes: L("Приложение падает при входе, если токен истёк. Нужно обновлять токен до запроса профиля и показывать понятную ошибку.",
                     "The app crashes on login when the token has expired. Refresh the token before the profile request and show a clear error."),
            createdBy: "Maria K.", createdAt: ago(48), tags: ["bug"], fields: [(name: "Priority", value: "High")],
            subtasks: [AsanaSubtask(id: "31", name: "Reproduce on iOS 17", completed: true, assignee: "Alex Demo", url: nil),
                       AsanaSubtask(id: "32", name: "Refresh the token before the request", completed: false, assignee: "Alex Demo", url: nil),
                       AsanaSubtask(id: "33", name: "Add a regression test", completed: false, assignee: nil, url: nil)],
            comments: [AsanaComment(id: "c1", author: "Maria K.", text: L("Воспроизводится после 30 минут простоя.", "Reproduces after 30 minutes idle."), createdAt: ago(20)),
                       AsanaComment(id: "c2", author: "Alex Demo", text: L("Нашёл причину, правлю.", "Found the cause, fixing it."), createdAt: ago(2))],
            attachments: [AsanaAttachment(id: "a1", name: "crash-log.txt", url: nil, size: 12_400, host: "asana", createdAt: ago(20))],
            parent: nil, blockedBy: [], blocking: [])
        store.useSample(tasks: tasks, order: ["To do", "In progress", "Review", "QA"], doneToday: 3, expanded: expanded ? "3" : nil, detail: expanded ? detail : nil)
    }

    private static func sampleNotes(_ store: NotesStore) {
        store.useSample([
            OmniNote(text: "Release checklist\n1. Bump version  2. Update changelog  3. Tag the build", createdAt: ago(80), modifiedAt: ago(1), pinned: true),
            OmniNote(text: "Meeting with design\nAgree on onboarding flow and empty states", createdAt: ago(30), modifiedAt: ago(6)),
            OmniNote(text: "Ideas\nShow unread count next to the Outlook button", createdAt: ago(100), modifiedAt: ago(26)),
        ])
    }
}
