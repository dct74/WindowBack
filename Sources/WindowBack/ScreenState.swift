import CoreGraphics
import Foundation

enum ScreenState {
    /// 锁屏/切换用户时窗口位置不可信，也不该在这时候动别人的窗口。
    static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
