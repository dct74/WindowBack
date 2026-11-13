import AppKit
import ApplicationServices
import Foundation

/// 监听各 App 的窗口事件：新窗口冒出、取消最小化。
/// 微信那种"展开后跑到屏外"就是取消最小化那一刻发生的，等显示器事件太晚。
final class AXEventWatcher {
    typealias Handler = (Int32, String) -> Void

    var onEvent: Handler?

    private var observers: [Int32: AXObserver] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            observe(pid: app.processIdentifier)
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(pid: app.processIdentifier)
        })
        workspaceTokens.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.remove(pid: app.processIdentifier)
        })
    }

    func stop() {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observers.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        for token in workspaceTokens { center.removeObserver(token) }
        workspaceTokens.removeAll()
        started = false
    }

    private func observe(pid: Int32) {
        guard started, observers[pid] == nil, pid > 0,
              pid != Int32(ProcessInfo.processInfo.processIdentifier) else { return }

        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<AXEventWatcher>.fromOpaque(refcon).takeUnretainedValue()
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let name = notification as String
            DispatchQueue.main.async { watcher.onEvent?(pid, name) }
        }

        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXWindowDeminiaturizedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, application, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    private func remove(pid: Int32) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
