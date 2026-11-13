import CoreGraphics
import Foundation

/// 一次采样到的窗口状态。
public struct WindowSample: Codable, Equatable {
    public var pid: Int32
    public var app: String
    public var title: String
    public var subrole: String
    public var frame: CGRect
    public var minimized: Bool
    public var fullscreen: Bool
    public var visibleRatio: Double
    public var offscreen: Bool
    /// 数据来源：ax（有标题/最小化状态）或 cg（仅窗口位置）
    public var source: String
    /// CG 窗口表里的 onscreen 标志：false 表示不在任何活动 Space 上（隐藏/别的桌面）
    public var onscreen: Bool

    public init(pid: Int32, app: String, title: String, subrole: String, frame: CGRect,
                minimized: Bool, fullscreen: Bool, visibleRatio: Double, offscreen: Bool,
                source: String = "cg", onscreen: Bool = true) {
        self.pid = pid
        self.app = app
        self.title = title
        self.subrole = subrole
        self.frame = frame
        self.minimized = minimized
        self.fullscreen = fullscreen
        self.visibleRatio = visibleRatio
        self.offscreen = offscreen
        self.source = source
        self.onscreen = onscreen
    }
}

public enum Thresholds {
    /// 可见面积低于此比例就当成"幽灵窗口"。
    public static let ghostRatio = 0.02
}

/// 只关心真正的窗口：面板、弹窗、状态栏之类不参与。
/// 注意 macOS 27 上 Safari / 访达 / 微信 / 信息 的主窗口 subrole 报的是 AXDialog，
/// 不能按"名字像对话框"过滤，只能列出明确要排除的系统面板。
public enum SubroleFilter {
    private static let ignored: Set<String> = [
        "AXSystemDialog", "AXFloatingWindow", "AXSystemFloatingWindow",
        "AXSheet", "AXDrawer", "AXPopover", "AXHelpTag"
    ]

    public static func isCandidate(_ subrole: String) -> Bool {
        !ignored.contains(subrole)
    }
}

/// 快照对比：找出位置/尺寸/最小化/可见性发生变化的窗口。
public struct WindowDelta: Codable {
    public var app: String
    public var title: String
    public var pid: Int32
    public var before: CGRect?
    public var after: CGRect?
    public var beforeVisibleRatio: Double
    public var afterVisibleRatio: Double
    public var minimizedBefore: Bool
    public var minimizedAfter: Bool
}

public enum SnapshotDiff {
    private static func key(_ s: WindowSample) -> String {
        "\(s.pid)|\(s.title)|\(s.frame.width)x\(s.frame.height)"
    }

    /// 以 (pid, 标题) 为身份做匹配；同一 App 多开时靠标题区分。
    public static func deltas(before: [WindowSample], after: [WindowSample]) -> [WindowDelta] {
        var old: [String: WindowSample] = [:]
        for s in before { old["\(s.pid)|\(s.title)"] = s }
        var new: [String: WindowSample] = [:]
        for s in after { new["\(s.pid)|\(s.title)"] = s }

        var out: [WindowDelta] = []
        for (id, now) in new {
            let prev = old[id]
            if let p = prev, p.frame == now.frame, p.minimized == now.minimized,
               abs(p.visibleRatio - now.visibleRatio) < 0.001 {
                continue
            }
            out.append(WindowDelta(
                app: now.app, title: now.title, pid: now.pid,
                before: prev?.frame, after: now.frame,
                beforeVisibleRatio: prev?.visibleRatio ?? 0,
                afterVisibleRatio: now.visibleRatio,
                minimizedBefore: prev?.minimized ?? false,
                minimizedAfter: now.minimized
            ))
        }
        _ = key
        return out.sorted { $0.app < $1.app }
    }
}
