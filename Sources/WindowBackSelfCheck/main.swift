import CoreGraphics
import Foundation
import WindowBackCore

/// 零依赖自检：`swift run WindowBackSelfCheck`，失败退出码 1。
var failures = 0
var checks = 0

func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition { return }
    failures += 1
    let extra = detail()
    print("FAIL: \(name)\(extra.isEmpty ? "" : " — \(extra)")")
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ name: String) {
    expect(a == b, name, "got \(a), want \(b)")
}

func expectClose(_ a: Double, _ b: Double, _ name: String, tolerance: Double = 0.001) {
    expect(abs(a - b) < tolerance, name, "got \(a), want \(b)")
}

let builtin = ScreenArea(
    displayID: 1,
    frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
    visibleFrame: CGRect(x: 0, y: 30, width: 1470, height: 896),
    isBuiltin: true, isAsleep: false
)
let external = ScreenArea(
    displayID: 2,
    frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1470, y: 30, width: 2560, height: 1410),
    isBuiltin: false, isAsleep: false
)

// MARK: 可见比例

expectClose(Geometry.visibleRatio(of: CGRect(x: 100, y: 100, width: 800, height: 600), in: [builtin, external]), 1,
            "内屏上的窗口可见比例 1")

let ghost = CGRect(x: 2400, y: 200, width: 800, height: 600)
expectClose(Geometry.visibleRatio(of: ghost, in: [builtin]), 0, "只有外屏坐标时不可见")
expect(Geometry.visibleRatio(of: ghost, in: [builtin]) < Thresholds.ghostRatio, "判定为幽灵窗口")

let straddle = CGRect(x: 1200, y: 100, width: 800, height: 600)
let straddleRatio = Geometry.visibleRatio(of: straddle, in: [builtin])
expect(straddleRatio > 0 && straddleRatio < 1, "跨屏窗口部分可见", "ratio=\(straddleRatio)")

// MARK: 屏幕归属

expectEqual(Geometry.hostScreen(of: CGRect(x: 1600, y: 100, width: 500, height: 400), in: [builtin, external])?.displayID,
            2, "外屏窗口归属外屏")
expectEqual(Geometry.hostScreen(of: CGRect(x: 100, y: 100, width: 500, height: 400), in: [builtin, external])?.displayID,
            1, "内屏窗口归属内屏")

// MARK: 归位

let pulled = Geometry.fit(ghost, into: builtin.visibleFrame)
expect(builtin.visibleFrame.contains(pulled), "屏外窗口被拉回可见区", "\(pulled)")
expectEqual(pulled.size, ghost.size, "拉回时不改尺寸")

let oversized = CGRect(x: 1570, y: -384, width: 2400, height: 1300)
let shrunk = Geometry.fit(oversized, into: builtin.visibleFrame)
expectEqual(shrunk.width, builtin.visibleFrame.width, "超宽窗口缩到屏宽")
expectEqual(shrunk.height, builtin.visibleFrame.height, "超高窗口缩到屏高")
expect(builtin.visibleFrame.contains(shrunk), "缩放后完整落在可见区")

let visible = CGRect(x: 200, y: 130, width: 880, height: 448)
expectEqual(Geometry.fit(visible, into: builtin.visibleFrame), visible, "已可见窗口不动")

let negative = CGRect(x: -500, y: -300, width: 700, height: 500)
let clampedNegative = Geometry.fit(negative, into: builtin.visibleFrame)
expectEqual(clampedNegative.origin.x, builtin.visibleFrame.minX, "负坐标 x 贴左边")
expectEqual(clampedNegative.origin.y, builtin.visibleFrame.minY, "负坐标 y 贴顶边")

// MARK: 硬伤判据（真实日志里的三种窗口）

let wechatAbove = CGRect(x: 711, y: -174, width: 880, height: 641)
expect(Geometry.isTitleBarUnreachable(wechatAbove, in: [builtin]), "标题栏在屏外 → 不可达")
expect(Geometry.isHardBroken(wechatAbove, in: [builtin]), "微信 58% 可见但标题栏够不着 → 需要救")
expectClose(Geometry.visibleRatio(of: wechatAbove, in: [builtin]), 0.58, "微信窗口可见比例", tolerance: 0.02)

let wechatSqueezed = CGRect(x: 1452, y: -32, width: 880, height: 641)
expect(Geometry.isHardBroken(wechatSqueezed, in: [builtin]), "只剩一条边可见 → 需要救")

let belowScreen = CGRect(x: 1371, y: 1001, width: 366, height: 420)
expect(Geometry.isHardBroken(belowScreen, in: [builtin]), "整条标题栏在屏幕下方 → 需要救")

let finderClipped = CGRect(x: 813, y: 12, width: 920, height: 492)
expect(!Geometry.isTitleBarUnreachable(finderClipped, in: [builtin]), "访达标题栏还在屏上 → 可达")
expect(!Geometry.isHardBroken(finderClipped, in: [builtin]), "只有右边缘超出 → 不自动动")

let normal = CGRect(x: 200, y: 130, width: 880, height: 448)
expect(!Geometry.isHardBroken(normal, in: [builtin]), "正常窗口不动")

let onExternal = CGRect(x: 1800, y: 200, width: 900, height: 600)
expect(!Geometry.isHardBroken(onExternal, in: [builtin, external]), "在外屏上正常显示 → 不动")
expect(Geometry.isHardBroken(onExternal, in: [builtin]), "外屏拔掉后 → 需要救")

// MARK: 软伤（部分出界）

expect(Geometry.isFullyOnScreen(normal, in: [builtin]), "完全在屏内")
expect(!Geometry.isPartiallyOff(normal, in: [builtin]), "完全在屏内不算软伤")

let underDock = CGRect(x: 100, y: 800, width: 800, height: 150)
expect(Geometry.isFullyOnScreen(underDock, in: [builtin]), "压在 Dock 上但仍在本屏范围内")
expect(!Geometry.isPartiallyOff(underDock, in: [builtin]), "不因 Dock 遮挡被判为出界")

// 跨两块屏摆放是正常的，不该被当成出界
let spanning = CGRect(x: 1200, y: 100, width: 800, height: 600)
expect(Geometry.isFullyOnScreen(spanning, in: [builtin, external]), "跨屏窗口在并集内")
expect(!Geometry.isPartiallyOff(spanning, in: [builtin, external]), "跨屏窗口不算软伤")
expect(Geometry.isPartiallyOff(spanning, in: [builtin]), "只剩内屏时跨屏窗口出界")

expect(Geometry.isPartiallyOff(finderClipped, in: [builtin]), "右边缘超出 → 软伤")
expect(!Geometry.isHardBroken(finderClipped, in: [builtin]), "但不算硬伤")
expect(Geometry.isPartiallyOff(wechatAbove, in: [builtin]), "标题栏在屏外 → 软伤（也属硬伤）")
expect(Geometry.isHardBroken(wechatAbove, in: [builtin]), "硬伤优先")

// MARK: 快照对比

func sample(_ title: String, _ f: CGRect, visible ratio: Double, minimized: Bool = false) -> WindowSample {
    WindowSample(pid: 42, app: "TestApp", title: title, subrole: "AXStandardWindow",
                 frame: f, minimized: minimized, fullscreen: false,
                 visibleRatio: ratio, offscreen: ratio < Thresholds.ghostRatio)
}

let same = sample("doc", CGRect(x: 10, y: 10, width: 100, height: 100), visible: 1)
expect(SnapshotDiff.deltas(before: [same], after: [same]).isEmpty, "无变化不产生 diff")

let moved = sample("doc", CGRect(x: 2400, y: 10, width: 100, height: 100), visible: 0)
let delta = SnapshotDiff.deltas(before: [same], after: [moved])
expectEqual(delta.count, 1, "移动产生一条 diff")
expectEqual(delta.first?.afterVisibleRatio ?? -1, 0, "diff 记录可见比例")

// MARK: 窗口类型过滤

expect(SubroleFilter.isCandidate("AXStandardWindow"), "标准窗口参与采样")
expect(SubroleFilter.isCandidate("AXFullScreenWindow"), "全屏窗口参与采样")
expect(SubroleFilter.isCandidate("AXDialog"), "macOS 27 真实窗口报 AXDialog，必须保留")
expect(!SubroleFilter.isCandidate("AXSystemDialog"), "系统对话框排除")
expect(!SubroleFilter.isCandidate("AXSheet"), "sheet 排除")

print(failures == 0 ? "OK: \(checks) checks passed" : "FAILED: \(failures)/\(checks)")
exit(failures == 0 ? 0 : 1)
