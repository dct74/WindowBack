import AppKit
import CoreGraphics
import Foundation
import WindowBackCore

enum DisplayQuery {
    /// 用 online 而不是 active：屏幕睡眠时 active 列表会短暂变空，
    /// 那会让"外屏拔掉"的判定误触发。
    static func screens() -> [ScreenArea] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        var result: [ScreenArea] = []
        for id in ids.prefix(Int(count)) {
            let frame = CGDisplayBounds(id)
            result.append(ScreenArea(
                displayID: id,
                frame: frame,
                visibleFrame: visibleFrame(for: id) ?? frame.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 26),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                isAsleep: CGDisplayIsAsleep(id) != 0
            ))
        }
        return result.sorted { $0.displayID < $1.displayID }
    }

    /// NSScreen 是左下原点，这里换算回 Quartz 的左上原点。
    private static func visibleFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryMaxY = primary.frame.maxY
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  number.uint32Value == displayID else { continue }
            let ns = screen.visibleFrame
            return CGRect(x: ns.minX, y: primaryMaxY - ns.maxY, width: ns.width, height: ns.height)
        }
        return nil
    }

    /// 签名要包含"是否点亮"：熄屏拔线后开盖亮屏，如果只比 id 和尺寸会被判成没变化。
    static func signature(_ screens: [ScreenArea]) -> String {
        screens.map {
            "\($0.displayID):\($0.isBuiltin ? "B" : "E"):\(Int($0.frame.width))x\(Int($0.frame.height))"
            + "@\(Int($0.frame.minX)),\(Int($0.frame.minY)):\($0.isAsleep ? "off" : "on")"
        }
        .joined(separator: " ")
    }
}
