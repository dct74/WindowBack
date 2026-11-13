import AppKit
import ServiceManagement
import WindowBackCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let watcher = DisplayWatcher()
    private let axEventWatcher = AXEventWatcher()
    private var lastWindowEventAt: Date?
    private var lastWindowEventPid: Int32 = 0
    private var lastSnapshot: [WindowSample] = []
    private var lastSnapshotAt: Date?
    private var lastEvent: DisplayEvent?
    private var burstSeq = 0
    private var burstWork: [DispatchWorkItem] = []
    private var autoFix = UserDefaults.standard.bool(forKey: "autoFix")
    private let burstDelays: [TimeInterval] = [0.05, 0.35, 0.8, 1.5, 2.5, 4.0, 7.0, 12.0]
    private let globalHotkey = GlobalHotkey()
    private var hotkeyAvailable = false
    private var wasLocked = false
    private var lastRescueNote = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let menuBarIcon = NSImage(named: "MenuBarIcon") {
            menuBarIcon.isTemplate = true
            statusItem.button?.image = menuBarIcon
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle",
                                               accessibilityDescription: "WindowBack")
            statusItem.button?.image?.isTemplate = true
        }
        buildMenu()

        Logger.shared.note("launch", [
            "axTrusted": WindowSampler.axTrusted,
            "screens": DisplayQuery.screens().count,
            "autoFix": autoFix,
            "log": Logger.shared.path
        ])
        lastSnapshot = WindowSampler.sample(screens: DisplayQuery.screens())
        Logger.shared.snapshot(lastSnapshot, trigger: "launch", seq: 0)

        watcher.onEvent = { [weak self] event in self?.handle(event) }
        watcher.start()

        axEventWatcher.onEvent = { [weak self] pid, notification in
            self?.handleWindowEvent(pid: pid, notification: notification)
        }
        axEventWatcher.start()

        hotkeyAvailable = globalHotkey.register { [weak self] in self?.toggleIconVisibility() }
        if !hotkeyAvailable {
            // 没有快捷键就绝不能把图标藏起来，否则没有入口可以叫回来。
            Logger.shared.note("global hotkey registration failed", ["hotkey": GlobalHotkey.displayName])
        }

        // 亮屏 / 解锁：熄屏状态下拔了外屏，这两条是唯一可靠的回收时机。
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screensDidWake),
                              name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake),
                              name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        wasLocked = ScreenState.isLocked
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let locked = ScreenState.isLocked
            if self.wasLocked && !locked { self.screenDidUnlock() }
            self.wasLocked = locked
        }

        // 兜底采样：事件之外的漂移（App 自己回写 frame、延迟生效）也能落盘。
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.periodicSample() }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Logger.shared.note("heartbeat", ["screens": DisplayQuery.screens().count, "autoFix": self.autoFix])
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher.stop()
        axEventWatcher.stop()
        Logger.shared.note("terminate")
    }

    // MARK: - 事件

    private func handle(_ event: DisplayEvent) {
        lastEvent = event
        let ghosts = lastSnapshot.filter { $0.offscreen }

        // 睡眠/唤醒也会触发回调，这里只记录、不跑 burst，避免日志噪音。
        Logger.shared.displayEvent(event, extra: [
            "lastSnapshotAge": lastSnapshotAt.map { Date().timeIntervalSince($0) } ?? -1,
            "offscreenBefore": ghosts.map { "\($0.app)/\($0.title)" }
        ])

        guard event.topologyChanged else {
            refreshMenuTitle()
            return
        }

        // 先补一条"变化前的已知状态"，再开始密集采样。
        if !lastSnapshot.isEmpty {
            Logger.shared.snapshot(lastSnapshot, trigger: "pre-event",
                                   seq: burstSeq, note: "captured \(lastSnapshotAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)ms before")
        }
        burst(reason: event.source)
        refreshMenuTitle()

        scheduleRescue(reason: "display(\(event.source))", delays: [0.4, 1.2, 3.0])
    }

    // MARK: - 亮屏 / 解锁触发

    @objc private func screensDidWake() {
        scheduleRescue(reason: "screensDidWake", delays: [0.15, 0.6, 1.5, 4.0])
    }

    @objc private func systemDidWake() {
        scheduleRescue(reason: "systemWake", delays: [0.5, 1.5, 4.0])
    }

    @objc private func screenDidUnlock() {
        scheduleRescue(reason: "unlock", delays: [0.1, 0.4, 1.2, 3.5])
    }

    private func scheduleRescue(reason: String, delays: [TimeInterval]) {
        guard autoFix else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.rescuePass(reason: reason)
            }
        }
    }

    /// 幂等：只处理当时确实出界的窗口，没有就什么都不做。
    private func rescuePass(reason: String) {
        guard autoFix, WindowSampler.axTrusted else { return }
        let screens = DisplayQuery.screens()
        guard screens.contains(where: { !$0.isAsleep }) else { return }
        let samples = WindowSampler.sample(screens: screens)
        let fixed = Rescue.run(samples: samples, screens: screens, reason: reason, aggressive: true)
        guard !fixed.isEmpty else { return }
        Logger.shared.note("rescue pass", ["reason": reason, "fixed": fixed])
        lastRescueNote = Date()
        lastSnapshot = samples
        lastSnapshotAt = Date()
        refreshMenuTitle()
    }

    private var lastOffscreenSignature = ""

    /// 只在"屏外窗口集合变化"时写盘，避免每分钟一条噪音。
    private func periodicSample() {
        guard !ScreenState.isLocked else { return }
        let screens = DisplayQuery.screens()
        let samples = WindowSampler.sample(screens: screens)
        let offscreen = samples.filter { $0.visibleRatio < 0.999 && !$0.minimized }
        let signature = offscreen.map { "\($0.pid)/\($0.title)/\(Int($0.frame.minX)),\(Int($0.frame.minY))" }
            .sorted().joined(separator: ",")
        lastSnapshot = samples
        lastSnapshotAt = Date()
        if signature != lastOffscreenSignature {
            lastOffscreenSignature = signature
            Logger.shared.snapshot(samples, trigger: "periodic", seq: 0,
                                   note: "partially-off set changed: \(offscreen.count) window(s)")
        }
        let broken = samples.filter { Geometry.isHardBroken($0.frame, in: screens) }
        if autoFix, !broken.isEmpty, WindowSampler.axTrusted {
            let fixed = Rescue.run(samples: broken, screens: screens, reason: "periodic")
            Logger.shared.note("periodic rescue", ["broken": broken.count, "fixed": fixed])
        }
        refreshMenuTitle()
    }

    private func burst(reason: String) {
        burstWork.forEach { $0.cancel() }
        burstWork.removeAll()
        burstSeq += 1
        let seq = burstSeq
        for (index, delay) in burstDelays.enumerated() {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let screens = DisplayQuery.screens()
                let samples = WindowSampler.sample(screens: screens)
                Logger.shared.snapshot(samples, trigger: "burst", seq: seq,
                                       note: "step \(index + 1)/\(self.burstDelays.count) after \(reason)")
                self.lastSnapshot = samples
                self.lastSnapshotAt = Date()
                self.refreshMenuTitle()
            }
            burstWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: - 归位

    @discardableResult
    private func rescueAll(automatic: Bool) -> Int {
        guard WindowSampler.axTrusted else {
            Logger.shared.note("rescue skipped: no accessibility permission", ["automatic": automatic])
            return 0
        }
        let screens = DisplayQuery.screens()
        guard !screens.isEmpty else { return 0 }
        let samples = WindowSampler.sample(screens: screens)
        let fixed = Rescue.run(samples: samples, screens: screens,
                               reason: automatic ? "display" : "manual", aggressive: true)
        let broken = samples.filter { Geometry.isHardBroken($0.frame, in: screens) }.count
        Logger.shared.note("rescue", [
            "automatic": automatic,
            "examined": samples.count,
            "broken": broken,
            "fixed": fixed
        ])
        lastSnapshot = samples
        lastSnapshotAt = Date()
        refreshMenuTitle()
        return fixed.count
    }

    /// 窗口事件（取消最小化 / 新窗口）：等窗口落定再检查，硬伤就拉回来。
    private func handleWindowEvent(pid: Int32, notification: String) {
        guard autoFix, WindowSampler.axTrusted else { return }
        let now = Date()
        if pid == lastWindowEventPid, let last = lastWindowEventAt, now.timeIntervalSince(last) < 1.0 { return }
        lastWindowEventPid = pid
        lastWindowEventAt = now
        // 先抢一个快照（窗口刚显形就修，用户看不到跳动），再补一次防止被 App 回写。
        for delay in [0.2, 0.8] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fixWindows(of: pid, reason: notification)
            }
        }
    }

    private func fixWindows(of pid: Int32, reason: String) {
        let screens = DisplayQuery.screens()
        guard !screens.isEmpty else { return }
        let samples = WindowSampler.sample(pid: pid, screens: screens)
        let broken = samples.filter { Geometry.isPartiallyOff($0.frame, in: screens) }
        guard !broken.isEmpty else { return }
        let fixed = Rescue.run(samples: samples, screens: screens,
                               reason: "windowEvent(\(reason))", aggressive: true)
        Logger.shared.note("window event", [
            "pid": Int(pid), "notification": reason,
            "broken": broken.count, "fixed": fixed
        ])
        lastSnapshot = WindowSampler.sample(screens: screens)
        lastSnapshotAt = Date()
        refreshMenuTitle()
    }

    // MARK: - 菜单

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let event = lastEvent {
            let line = NSMenuItem(title: eventLine(event), action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
        }
        menu.addItem(.separator())

        menu.addItem(item("立即采样并写日志", #selector(sampleNow)))
        let rescueItem = item("把屏外窗口收回内屏", #selector(rescueNow))
        rescueItem.isEnabled = WindowSampler.axTrusted
        menu.addItem(rescueItem)

        let auto = item("自动归位（外屏→内屏时）", #selector(toggleAutoFix))
        auto.state = autoFix ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        if !WindowSampler.axTrusted {
            menu.addItem(item("授权辅助功能…", #selector(requestTrust)))
        }
        let login = item("开机启动", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("打开日志", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    private func statusText() -> String {
        let ghosts = lastSnapshot.filter { $0.offscreen && !$0.minimized }
        let screens = DisplayQuery.screens()
        let topology = screens.map { "\($0.isBuiltin ? "内" : "外")\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: " + ")
        var parts = ["屏: \(topology.isEmpty ? "无" : topology)"]
        parts.append(ghosts.isEmpty ? "屏外窗口: 0" : "屏外窗口: \(ghosts.count)")
        if !WindowSampler.axTrusted { parts.append("未授权辅助功能") }
        return parts.joined(separator: " · ")
    }

    private func eventLine(_ event: DisplayEvent) -> String {
        let delta = event.topologyChanged ? "拓扑变化" : "无拓扑变化"
        return "上次事件: \(delta) [\(event.flags.joined(separator: ","))]"
    }

    private func refreshMenuTitle() {
        statusItem.button?.toolTip = statusText()
        if let menu = statusItem.menu { rebuild(menu) }
    }

    @objc private func sampleNow() {
        lastSnapshot = WindowSampler.sample(screens: DisplayQuery.screens())
        lastSnapshotAt = Date()
        Logger.shared.snapshot(lastSnapshot, trigger: "manual", seq: 0)
        refreshMenuTitle()
    }

    @objc private func rescueNow() {
        let count = rescueAll(automatic: false)
        statusItem.button?.toolTip = "已收回 \(count) 个窗口"
    }

    @objc private func toggleAutoFix() {
        autoFix.toggle()
        UserDefaults.standard.set(autoFix, forKey: "autoFix")
        Logger.shared.note("autoFix", ["enabled": autoFix])
        refreshMenuTitle()
    }

    @objc private func requestTrust() {
        WindowSampler.requestAXTrust()
        Logger.shared.note("requested accessibility permission")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            Logger.shared.note("login item", ["status": SMAppService.mainApp.status.rawValue])
        } catch {
            Logger.shared.note("login item failed", ["error": error.localizedDescription])
            let alert = NSAlert()
            alert.messageText = "开机启动设置失败"
            alert.informativeText = "\(error.localizedDescription)\n\n请把 WindowBack.app 放进 /Applications 后再试，或到「系统设置 → 通用 → 登录项」手动添加。"
            alert.runModal()
        }
        refreshMenuTitle()
    }

    /// 隐藏后菜单栏就没有入口了，只能靠同一个快捷键切回来。
    private func toggleIconVisibility() {
        guard let statusItem else { return }
        statusItem.isVisible.toggle()
        Logger.shared.note(statusItem.isVisible ? "menu bar icon shown" : "menu bar icon hidden",
                           ["hotkey": GlobalHotkey.displayName])
        if statusItem.isVisible { refreshMenuTitle() }
    }

    @objc private func toggleIcon() {
        toggleIconVisibility()
    }

    @objc private func openLog() {
        NSWorkspace.shared.selectFile(Logger.shared.path, inFileViewerRootedAtPath: "")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}
