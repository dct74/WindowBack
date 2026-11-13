import AppKit
import ServiceManagement
import WindowBackCore

let app = NSApplication.shared

// 安装脚本用：--register-login 注册开机启动后立即退出。
if CommandLine.arguments.contains("--register-login") {
    do {
        try SMAppService.mainApp.register()
        print("registered: \(SMAppService.mainApp.status.rawValue)")
    } catch {
        print("register failed: \(error.localizedDescription)")
    }
    if CommandLine.arguments.contains("--unregister-login") {
        try? SMAppService.mainApp.unregister()
        print("unregistered: \(SMAppService.mainApp.status.rawValue)")
    }
    exit(0)
}

if CommandLine.arguments.contains("--unregister-login") {
    try? SMAppService.mainApp.unregister()
    print("unregistered: \(SMAppService.mainApp.status.rawValue)")
    exit(0)
}

// 调试用：--rescue-now 采一次、修一次、打印结果、退出（不启动菜单栏）。
if CommandLine.arguments.contains("--rescue-now") || CommandLine.arguments.contains("--dump") {
    let screens = DisplayQuery.screens()
    let samples = WindowSampler.sample(screens: screens)
    let broken = samples.filter { Geometry.isHardBroken($0.frame, in: screens) }
    if CommandLine.arguments.contains("--dump") {
        for window in samples {
            print("\(window.source) \(window.app) / \(window.title) \(Int(window.frame.width))x\(Int(window.frame.height))"
                  + "@\(Int(window.frame.minX)),\(Int(window.frame.minY)) vis=\(String(format: "%.2f", window.visibleRatio))"
                  + " min=\(window.minimized) hard=\(Geometry.isHardBroken(window.frame, in: screens))"
                  + " off=\(Geometry.isPartiallyOff(window.frame, in: screens))")
        }
    }
    print("screens=\(screens.count) windows=\(samples.count) broken=\(broken.count) axTrusted=\(WindowSampler.axTrusted)")
    // --dump 只读；--rescue-now 才动手。
    if !CommandLine.arguments.contains("--dump") {
        let fixed = Rescue.run(samples: samples, screens: screens, reason: "cli", aggressive: true)
        for entry in fixed { print("fixed: \(entry)") }
    }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
