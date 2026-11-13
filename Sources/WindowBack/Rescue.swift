import CoreGraphics
import Foundation
import WindowBackCore

enum Rescue {
    static func targetScreen(_ screens: [ScreenArea]) -> ScreenArea? {
        screens.first { $0.isBuiltin && !$0.isAsleep } ?? screens.first
    }

    /// aggressive = false：只救"硬伤"（可见 <5% 或标题栏在屏外）。
    /// aggressive = true ：连"没完整落在屏内"也一起收回（显示器变化后、窗口刚显形时用）。
    static func run(samples: [WindowSample], screens: [ScreenArea], reason: String,
                    aggressive: Bool = false) -> [[String: Any]] {
        guard !screens.isEmpty else { return [] }
        let fallback = targetScreen(screens)?.visibleFrame ?? screens[0].visibleFrame
        var fixed: [[String: Any]] = []
        for sample in samples where aggressive ? Geometry.isPartiallyOff(sample.frame, in: screens)
                                                 : Geometry.isHardBroken(sample.frame, in: screens) {
            let target = Geometry.hostScreen(of: sample.frame, in: screens)?.visibleFrame ?? fallback
            let fitted = Geometry.fit(sample.frame, into: target)
            guard fitted != sample.frame else { continue }
            let ok = WindowSampler.setFrame(fitted, of: sample)
            fixed.append([
                "app": sample.app, "title": sample.title, "ok": ok, "reason": reason,
                "minimized": sample.minimized, "source": sample.source,
                "from": [sample.frame.origin.x, sample.frame.origin.y, sample.frame.width, sample.frame.height],
                "to": [fitted.origin.x, fitted.origin.y, fitted.width, fitted.height]
            ])
        }
        return fixed
    }
}
