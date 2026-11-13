import AppKit
import ApplicationServices
import CoreGraphics
import WindowBackCore

enum WindowSampler {
    static var axTrusted: Bool { AXIsProcessTrusted() }

    static func requestAXTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 采样所有 App 的窗口。CG 窗口表是主数据（位置永远可靠），
    /// AX 只用来补充标题/最小化状态——它对后台 App 经常返回 attributeUnsupported。
    static func sample(screens: [ScreenArea]) -> [WindowSample] {
        let cg = sampleViaCG(screens: screens, only: nil)
        let ax = axTrusted ? sampleViaAX(screens: screens, only: nil, owners: Set(cg.map { $0.pid })) : []
        return merge(cg: cg, ax: ax)
    }

    /// 只采一个 App，用于窗口事件触发的即时检查。
    static func sample(pid: Int32, screens: [ScreenArea]) -> [WindowSample] {
        let cg = sampleViaCG(screens: screens, only: pid)
        let ax = axTrusted ? sampleViaAX(screens: screens, only: pid, owners: [pid]) : []
        return merge(cg: cg, ax: ax)
    }

    /// AX 是主数据（标题、最小化、真实 frame），CG 只用来补 onscreen 标志，
    /// 以及补上 AX 完全暴露不到的窗口（部分 App 的窗口不在 AX 树里）。
    private static func merge(cg: [WindowSample], ax: [WindowSample]) -> [WindowSample] {
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
        }

        var used = Set<Int>()
        var out: [WindowSample] = []
        for var window in ax {
            var best = (index: -1, distance: CGFloat.greatestFiniteMagnitude)
            for (i, candidate) in cg.enumerated() where candidate.pid == window.pid && !used.contains(i) {
                let d = distance(candidate.frame, window.frame)
                if d < best.distance { best = (i, d) }
            }
            if best.index >= 0, best.distance <= 8 {
                used.insert(best.index)
                window.onscreen = cg[best.index].onscreen
            } else {
                window.onscreen = false
            }
            out.append(window)
        }

        // 锁屏时整张表都没有 onscreen 标志，这时不能按 onscreen 过滤，否则全丢。
        let anyOnscreen = cg.contains { $0.onscreen }
        for (i, window) in cg.enumerated() where !used.contains(i) {
            guard !isPlaceholder(window) else { continue }
            if window.onscreen || !anyOnscreen { out.append(window) }
        }

        // 同一个窗口被 AX 和 CG 各报一次（App 多进程时 pid 不同，上面的匹配接不住）时去重。
        func identity(_ window: WindowSample) -> String {
            "\(window.app)|\(Int(window.frame.minX)),\(Int(window.frame.minY)),\(Int(window.frame.width)),\(Int(window.frame.height))"
        }
        let axIdentities = Set(out.filter { $0.source == "ax" }.map(identity))
        return out.filter { $0.source == "ax" || !axIdentities.contains(identity($0)) }
    }

    /// 系统给隐藏窗口留的占位窗口：500x500、没有 onscreen 标志。
    /// Siri / loginwindow / ClipHistory / UserNotificationCenter 都有一份，纯噪音。
    private static func isPlaceholder(_ window: WindowSample) -> Bool {
        !window.onscreen && window.frame.width == 500 && window.frame.height == 500
    }

    private static func appIsCandidate(_ app: NSRunningApplication) -> Bool {
        app.activationPolicy == .regular || app.activationPolicy == .accessory
    }

    /// 只问"确实有窗口"的进程。菜单栏小程序几十个，挨个发 AX 请求会拖到 3 秒以上。
    private static func sampleViaAX(screens: [ScreenArea], only: Int32?,
                                    owners: Set<Int32>) -> [WindowSample] {
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        var out: [WindowSample] = []
        for app in NSWorkspace.shared.runningApplications {
            guard appIsCandidate(app), app.processIdentifier != ownPID else { continue }
            guard owners.contains(app.processIdentifier) else { continue }
            if let only, app.processIdentifier != only { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            // 无响应 App 会让 AX 调用挂住（锁屏/卡死时尤其明显），限 1 秒。
            AXUIElementSetMessagingTimeout(element, 0.25)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }

            for window in windows {
                guard string(window, kAXRoleAttribute) == "AXWindow" else { continue }
                let subrole = string(window, kAXSubroleAttribute) ?? ""
                guard SubroleFilter.isCandidate(subrole) else { continue }
                guard let frame = axFrame(of: window), frame.width >= 100, frame.height >= 100 else { continue }
                let visible = Geometry.visibleRatio(of: frame, in: screens)
                out.append(WindowSample(
                    pid: app.processIdentifier,
                    app: app.localizedName ?? app.bundleIdentifier ?? "?",
                    title: string(window, kAXTitleAttribute) ?? "",
                    subrole: subrole,
                    frame: frame,
                    minimized: bool(window, kAXMinimizedAttribute),
                    fullscreen: bool(window, "AXFullScreen"),
                    visibleRatio: visible,
                    offscreen: visible < Thresholds.ghostRatio,
                    source: "ax"
                ))
            }
        }
        return out
    }

    private static func sampleViaCG(screens: [ScreenArea], only: Int32?) -> [WindowSample] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [NSDictionary] else { return [] }
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let policy: [Int32: NSApplication.ActivationPolicy] = Dictionary(
            uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0.activationPolicy) }
        )
        var out: [WindowSample] = []
        for entry in list {
            guard let pid = entry[kCGWindowOwnerPID] as? Int32, pid != ownPID else { continue }
            if let only, pid != only { continue }
            guard let layer = entry[kCGWindowLayer] as? Int, layer == 0 else { continue }
            switch policy[pid] ?? .prohibited {
            case .regular, .accessory: break
            default: continue
            }
            guard let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            guard frame.width >= 100, frame.height >= 100 else { continue }
            let onscreen = (entry[kCGWindowIsOnscreen] as? NSNumber)?.boolValue ?? false
            let visible = Geometry.visibleRatio(of: frame, in: screens)
            out.append(WindowSample(
                pid: pid,
                app: entry[kCGWindowOwnerName] as? String ?? "?",
                title: entry[kCGWindowName] as? String ?? "",
                subrole: "CGWindow",
                frame: frame,
                minimized: false,
                fullscreen: false,
                visibleRatio: visible,
                offscreen: visible < Thresholds.ghostRatio,
                source: "cg",
                onscreen: onscreen
            ))
        }
        return out
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    private static func axFrame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionRef = positionValue, let sizeRef = sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// 把窗口写回指定矩形。先改尺寸再改位置——大窗口先设位置会被屏幕约束挡回来。
    /// 写完后读回校验，位置对不上重试一次。
    static func setFrame(_ frame: CGRect, of sample: WindowSample) -> Bool {
        let element = AXUIElementCreateApplication(sample.pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }

        var best: (window: AXUIElement, distance: CGFloat)?
        for window in windows {
            guard string(window, kAXRoleAttribute) == "AXWindow" else { continue }
            guard let current = axFrame(of: window) else { continue }
            let dx = abs(current.minX - sample.frame.minX)
            let dy = abs(current.minY - sample.frame.minY)
            let dw = abs(current.width - sample.frame.width)
            let dh = abs(current.height - sample.frame.height)
            let d = dx + dy + dw + dh
            if best == nil || d < best!.distance { best = (window, d) }
        }
        // 位置对不上说明窗口已经变了，别动别人的窗口。
        guard let target = best, target.distance <= 24 else { return false }

        for _ in 0..<2 {
            var size = frame.size
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(target.window, kAXSizeAttribute as CFString, sizeValue)
            }
            var point = frame.origin
            if let pointValue = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(target.window, kAXPositionAttribute as CFString, pointValue)
            }
            // 尺寸可能被 App 的 min/max 约束改掉，位置对得上就算成功。
            if let now = axFrame(of: target.window),
               abs(now.minX - frame.minX) <= 2, abs(now.minY - frame.minY) <= 2 {
                return true
            }
        }
        return false
    }
}

extension CGRect {
    init?(dictionaryRepresentation dict: NSDictionary) {
        guard let x = dict["X"] as? CGFloat, let y = dict["Y"] as? CGFloat,
              let width = dict["Width"] as? CGFloat, let height = dict["Height"] as? CGFloat else { return nil }
        self.init(x: x, y: y, width: width, height: height)
    }
}
