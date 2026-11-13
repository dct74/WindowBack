import AppKit
import CoreGraphics
import WindowBackCore

/// 屏幕拓扑变化事件（已防抖、已排除睡眠唤醒造成的假变化）。
struct DisplayEvent {
    var source: String
    var flags: [String]
    var previous: [ScreenArea]
    var current: [ScreenArea]
    var topologyChanged: Bool
    var nowBuiltinOnly: Bool
}

final class DisplayWatcher {
    var onEvent: ((DisplayEvent) -> Void)?

    private var previous: [ScreenArea]
    private var pendingFlags: Set<String> = []
    private var pendingSources: Set<String> = []
    private var debounce: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.25
    private var registered = false

    init() {
        previous = DisplayQuery.screens()
    }

    func start() {
        guard !registered else { return }
        registered = true
        CGDisplayRegisterReconfigurationCallback(DisplayWatcher.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.note(flags: ["appkitNotification"], source: "appkit")
        }
    }

    func stop() {
        guard registered else { return }
        registered = false
        CGDisplayRemoveReconfigurationCallback(DisplayWatcher.reconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    private func note(flags: [String], source: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFlags.formUnion(flags)
            self.pendingSources.insert(source)
            self.debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            self.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceInterval, execute: work)
        }
    }

    /// 回调里拿到的显示器列表可能是过渡态（0 个屏 / 少一个屏），
    /// 所以等 0.45s 稳定后再取一次，并和上一次稳定拓扑比较。
    private func settle() {
        let current = DisplayQuery.screens()
        guard !current.isEmpty else {
            // 过渡态，再等一轮
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            return
        }
        let previousSignature = DisplayQuery.signature(previous)
        let currentSignature = DisplayQuery.signature(current)
        let topologyChanged = previousSignature != currentSignature
        let event = DisplayEvent(
            source: pendingSources.sorted().joined(separator: "+"),
            flags: pendingFlags.sorted(),
            previous: previous,
            current: current,
            topologyChanged: topologyChanged,
            nowBuiltinOnly: current.allSatisfy { $0.isBuiltin } && !previous.allSatisfy { $0.isBuiltin }
        )
        pendingFlags.removeAll()
        pendingSources.removeAll()
        if topologyChanged { previous = current }
        onEvent?(event)
    }

    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard let context else { return }
        let watcher = Unmanaged<DisplayWatcher>.fromOpaque(context).takeUnretainedValue()
        watcher.note(flags: DisplayWatcher.describe(flags), source: "cg")
    }

    private static func describe(_ flags: CGDisplayChangeSummaryFlags) -> [String] {
        var out: [String] = []
        let map: [(CGDisplayChangeSummaryFlags, String)] = [
            (.beginConfigurationFlag, "beginConfiguration"),
            (.addFlag, "add"),
            (.removeFlag, "remove"),
            (.enabledFlag, "enabled"),
            (.disabledFlag, "disabled"),
            (.mirrorFlag, "mirror"),
            (.movedFlag, "moved"),
            (.setMainFlag, "setMain"),
            (.setModeFlag, "setMode"),
            (.desktopShapeChangedFlag, "shapeChanged")
        ]
        for (flag, name) in map where flags.contains(flag) { out.append(name) }
        return out
    }
}
