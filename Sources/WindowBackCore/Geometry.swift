import CoreGraphics

/// 屏幕可见区域（Quartz 全局坐标：原点左上、y 向下）。
public struct ScreenArea: Codable, Equatable {
    public var displayID: UInt32
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var isBuiltin: Bool
    public var isAsleep: Bool

    public init(displayID: UInt32, frame: CGRect, visibleFrame: CGRect, isBuiltin: Bool, isAsleep: Bool) {
        self.displayID = displayID
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isBuiltin = isBuiltin
        self.isAsleep = isAsleep
    }
}

public enum Geometry {
    /// 硬伤阈值：可见面积低于这个比例就认为窗口基本废了。
    public static let hardMinimumRatio = 0.05
    /// 标题栏条带高度（pt），用来判断窗口还能不能被抓住。
    public static let titleBarHeight: CGFloat = 30

    /// 窗口被任一屏幕可见区覆盖的面积比例（0…1）。
    /// 用可见区而不是整块屏，避免把 Dock/菜单栏下方的窗口误判为"可见"。
    public static func visibleRatio(of frame: CGRect, in screens: [ScreenArea]) -> Double {
        guard frame.width > 0, frame.height > 0 else { return 0 }
        var best: CGFloat = 0
        for screen in screens {
            let hit = frame.intersection(screen.visibleFrame)
            if hit.isNull { continue }
            best = max(best, hit.width * hit.height)
        }
        let ratio = Double(best / (frame.width * frame.height))
        return min(max(ratio, 0), 1)
    }

    /// 找出窗口当前所在（覆盖面积最大）的屏幕；都不相交时返回 nil。
    public static func hostScreen(of frame: CGRect, in screens: [ScreenArea]) -> ScreenArea? {
        var best: (ScreenArea, CGFloat)?
        for screen in screens {
            let hit = frame.intersection(screen.visibleFrame)
            if hit.isNull { continue }
            let area = hit.width * hit.height
            if best == nil || area > best!.1 { best = (screen, area) }
        }
        return best?.0
    }

    /// 标题栏整条（窗口顶部 30pt）与所有屏幕都不相交 → 抓不住、拖不动。
    public static func isTitleBarUnreachable(_ frame: CGRect, in screens: [ScreenArea]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return true }
        let bar = CGRect(x: frame.minX, y: frame.minY,
                         width: frame.width, height: min(titleBarHeight, frame.height))
        for screen in screens {
            let hit = bar.intersection(screen.visibleFrame)
            if !hit.isNull && hit.width > 1 && hit.height > 1 { return false }
        }
        return true
    }

    /// 完整落在所有屏幕的并集里（不扣菜单栏/Dock，避免把"压在 Dock 下面的窗口"当成问题）。
    /// 用面积覆盖而不是单块屏幕包含：跨两块屏摆放的窗口是正常的，不该被收回来。
    public static func isFullyOnScreen(_ frame: CGRect, in screens: [ScreenArea]) -> Bool {
        guard !screens.isEmpty else { return false }
        let area = frame.width * frame.height
        guard area > 0 else { return true }
        var covered: CGFloat = 0
        for screen in screens {
            let hit = frame.intersection(screen.frame)
            if !hit.isNull { covered += hit.width * hit.height }
        }
        return covered >= area - 0.5
    }

    /// 软伤：没有完整落在任何一块屏幕里，但还看得见、抓得住。
    public static func isPartiallyOff(_ frame: CGRect, in screens: [ScreenArea]) -> Bool {
        !isFullyOnScreen(frame, in: screens)
    }

    /// 需要自动介入的"硬伤"：几乎看不见，或者标题栏已经够不着。
    public static func isHardBroken(_ frame: CGRect, in screens: [ScreenArea]) -> Bool {
        if visibleRatio(of: frame, in: screens) < hardMinimumRatio { return true }
        return isTitleBarUnreachable(frame, in: screens)
    }

    /// 把窗口收回目标可见区：先缩到能放进屏幕，再平移进边界。
    /// 已经完整落在区域内时原样返回。
    public static func fit(_ frame: CGRect, into target: CGRect) -> CGRect {
        let width = min(frame.width, target.width)
        let height = min(frame.height, target.height)
        var result = CGRect(x: frame.origin.x, y: frame.origin.y, width: width, height: height)
        if target.contains(result) { return frame }
        let maxX = target.maxX - width
        let maxY = target.maxY - height
        result.origin.x = min(max(result.origin.x, target.minX), maxX)
        result.origin.y = min(max(result.origin.y, target.minY), maxY)
        return result
    }
}
