import CoreGraphics
import Foundation
import WindowBackCore

/// JSONL 日志：一行一个事件，方便事后用 jq/脚本分析。
final class Logger {
    static let shared = Logger()

    private let directory: URL
    private let fileURL: URL
    private let queue = DispatchQueue(label: "dev.dct74.windowback.log")
    private var handle: FileHandle?
    private let rotateAt: UInt64 = 8 * 1024 * 1024

    private init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WindowBack", isDirectory: true)
        directory = logs
        fileURL = logs.appendingPathComponent("monitor.log")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        rotateIfNeeded()
        handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
    }

    var path: String { fileURL.path }

    func displayEvent(_ event: DisplayEvent, extra: [String: Any] = [:]) {
        var payload: [String: Any] = [
            "kind": "display",
            "source": event.source,
            "flags": event.flags,
            "topologyChanged": event.topologyChanged,
            "nowBuiltinOnly": event.nowBuiltinOnly,
            "previous": encode(screens: event.previous),
            "current": encode(screens: event.current)
        ]
        for (k, v) in extra { payload[k] = v }
        write(payload)
    }

    func snapshot(_ windows: [WindowSample], trigger: String, seq: Int, note: String = "") {
        let entries: [[String: Any]] = windows.map { w in
            [
                "pid": Int(w.pid), "app": w.app, "title": w.title, "subrole": w.subrole,
                "x": w.frame.origin.x, "y": w.frame.origin.y,
                "w": w.frame.width, "h": w.frame.height,
                "minimized": w.minimized, "fullscreen": w.fullscreen, "source": w.source, "onscreen": w.onscreen,
                "visibleRatio": (w.visibleRatio * 1000).rounded() / 1000,
                "offscreen": w.offscreen
            ]
        }
        var payload: [String: Any] = [
            "kind": "snapshot", "trigger": trigger, "seq": seq,
            "axTrusted": WindowSampler.axTrusted,
            "screens": encode(screens: DisplayQuery.screens()),
            "windows": entries
        ]
        if !note.isEmpty { payload["note"] = note }
        write(payload)
    }

    func note(_ message: String, _ extra: [String: Any] = [:]) {
        var payload: [String: Any] = ["kind": "note", "message": message]
        for (k, v) in extra { payload[k] = v }
        write(payload)
    }

    private func encode(screens: [ScreenArea]) -> [[String: Any]] {
        screens.map { s in
            [
                "id": Int(s.displayID), "builtin": s.isBuiltin, "asleep": s.isAsleep,
                "x": s.frame.origin.x, "y": s.frame.origin.y,
                "w": s.frame.width, "h": s.frame.height,
                "vx": s.visibleFrame.origin.x, "vy": s.visibleFrame.origin.y,
                "vw": s.visibleFrame.width, "vh": s.visibleFrame.height
            ]
        }
    }

    private func write(_ payload: [String: Any]) {
        var dict = payload
        dict["t"] = ISO8601DateFormatter.threadSafe.string(from: Date())
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        queue.async { [weak self] in
            guard let self, let handle = self.handle, let data = line.data(using: .utf8) else { return }
            handle.write(data)
            if handle.offsetInFile > self.rotateAt {
                handle.closeFile()
                self.handle = nil
                self.rotateIfNeeded()
                self.handle = try? FileHandle(forWritingTo: self.fileURL)
            }
        }
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64, size > rotateAt else { return }
        let old = directory.appendingPathComponent("monitor.1.log")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: fileURL, to: old)
    }
}

extension ISO8601DateFormatter {
    static let threadSafe: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
