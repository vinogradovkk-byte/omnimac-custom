import AppKit
import ApplicationServices
import Combine

private let vsCodeAXObserverCallback: AXObserverCallback = { _, _, _, context in
    guard let context else { return }
    let monitor = Unmanaged<VSCodeWindowMonitor>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async {
        monitor.accessibilityEventReceived()
    }
}

final class VSCodeWindowMonitor: ObservableObject {
    @Published private(set) var windows: [VSCodeWindow] = []

    private var started = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private var accessibilityObserver: AXObserver?
    private var observedApplication: AXUIElement?
    private var observedPID: pid_t?
    private var observedWindows: [CGWindowID: AXUIElement] = [:]
    private var refreshWorkItem: DispatchWorkItem?

    func start() {
        guard !started else { return }
        started = true

        let center = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.workspaceEventReceived(notification)
            }
        }
        refresh()
    }

    func stop() {
        guard started else { return }
        started = false
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        detachAccessibilityObserver()
        windows = []
    }

    func refresh() {
        guard started else { return }
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        guard AXIsProcessTrusted(), let app = runningVSCode() else {
            detachAccessibilityObserver()
            windows = []
            return
        }

        if observedPID != app.processIdentifier || accessibilityObserver == nil {
            attachAccessibilityObserver(to: app.processIdentifier)
        }

        let discovered = VSCodeWindowProvider.windows()
        reconcileWindowNotifications(with: discovered)
        windows = discovered
    }

    fileprivate func accessibilityEventReceived() {
        scheduleRefresh()
    }

    private func workspaceEventReceived(_ notification: Notification) {
        if notification.name == NSWorkspace.didTerminateApplicationNotification,
           let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
           app.processIdentifier == observedPID {
            detachAccessibilityObserver()
            windows = []
            return
        }

        // Activation is also the bounded retry point after Accessibility permission
        // changes. It is an event, not a background polling loop.
        refresh()
    }

    private func runningVSCode() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            VSCodeWindowProvider.isSupported(bundleIdentifier: $0.bundleIdentifier)
        }
    }

    private func attachAccessibilityObserver(to pid: pid_t) {
        detachAccessibilityObserver()

        var observer: AXObserver?
        guard AXObserverCreate(pid, vsCodeAXObserverCallback, &observer) == .success,
              let observer else { return }

        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
            _ = AXObserverAddNotification(observer, application, notification as CFString, context)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        accessibilityObserver = observer
        observedApplication = application
        observedPID = pid
    }

    private func reconcileWindowNotifications(with currentWindows: [VSCodeWindow]) {
        guard let observer = accessibilityObserver else { return }
        let currentIDs = Set(currentWindows.map(\.id))
        let notifications = [
            kAXUIElementDestroyedNotification,
            kAXTitleChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
        ]

        for (id, element) in observedWindows where !currentIDs.contains(id) {
            for notification in notifications {
                _ = AXObserverRemoveNotification(observer, element, notification as CFString)
            }
            observedWindows[id] = nil
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        for window in currentWindows where observedWindows[window.id] == nil {
            guard let element = window.element else { continue }
            for notification in notifications {
                _ = AXObserverAddNotification(observer, element, notification as CFString, context)
            }
            observedWindows[window.id] = element
        }
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func detachAccessibilityObserver() {
        refreshWorkItem?.cancel()
        refreshWorkItem = nil

        if let observer = accessibilityObserver {
            for element in observedWindows.values {
                for notification in [
                    kAXUIElementDestroyedNotification,
                    kAXTitleChangedNotification,
                    kAXWindowMiniaturizedNotification,
                    kAXWindowDeminiaturizedNotification,
                ] {
                    _ = AXObserverRemoveNotification(observer, element, notification as CFString)
                }
            }
            if let application = observedApplication {
                for notification in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                    _ = AXObserverRemoveNotification(observer, application, notification as CFString)
                }
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .commonModes
            )
        }

        observedWindows.removeAll()
        observedApplication = nil
        accessibilityObserver = nil
        observedPID = nil
    }
}
