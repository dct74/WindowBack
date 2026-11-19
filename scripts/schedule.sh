#!/bin/bash
# 用 launchd 定时启动/退出 WindowBack（周一到周五 17:50 启动，09:00 退出）。
#
#   ./scripts/schedule.sh install     安装并加载
#   ./scripts/schedule.sh uninstall   卸载
#   ./scripts/schedule.sh status      看状态与下次触发时间
#
# 说明：
# - LaunchAgent 只在用户登录后生效；Mac 睡眠时错过的时刻会在唤醒后补跑。
# - 退出用 SIGTERM，App 会走 applicationWillTerminate，日志里有 terminate 记录。
set -euo pipefail

APP="/Applications/WindowBack.app"
BIN="$APP/Contents/MacOS/WindowBack"
START_LABEL="dev.dct74.windowback.schedule.start"
STOP_LABEL="dev.dct74.windowback.schedule.stop"
AGENTS="$HOME/Library/LaunchAgents"
LOGDIR="$HOME/Library/Logs/WindowBack"

start_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${START_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>${APP}</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>17</integer><key>Minute</key><integer>50</integer></dict>
        <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>17</integer><key>Minute</key><integer>50</integer></dict>
        <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>17</integer><key>Minute</key><integer>50</integer></dict>
        <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>17</integer><key>Minute</key><integer>50</integer></dict>
        <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>17</integer><key>Minute</key><integer>50</integer></dict>
    </array>
    <key>StandardOutPath</key><string>${LOGDIR}/launchd-start.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/launchd-start.log</string>
</dict>
</plist>
PLIST
}

stop_plist() {
    cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${STOP_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/usr/bin/pkill -TERM -f '${BIN}' || true</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Weekday</key><integer>1</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Weekday</key><integer>2</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Weekday</key><integer>3</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Weekday</key><integer>4</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Weekday</key><integer>5</integer><key>Hour</key><integer>9</integer><key>Minute</key><integer>0</integer></dict>
    </array>
    <key>StandardOutPath</key><string>${LOGDIR}/launchd-stop.log</string>
    <key>StandardErrorPath</key><string>${LOGDIR}/launchd-stop.log</string>
</dict>
</plist>
PLIST
}

load_agent() {
    local label=$1 plist=$2
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
}

case "${1:-status}" in
install)
    mkdir -p "$AGENTS" "$LOGDIR"
    start_plist > "$AGENTS/$START_LABEL.plist"
    stop_plist  > "$AGENTS/$STOP_LABEL.plist"
    load_agent "$START_LABEL" "$AGENTS/$START_LABEL.plist"
    load_agent "$STOP_LABEL"  "$AGENTS/$STOP_LABEL.plist"
    echo "已安装：周一到周五 17:50 启动，09:00 退出"
    exec "${BASH_SOURCE[0]}" status
    ;;
uninstall)
    launchctl bootout "gui/$(id -u)/$START_LABEL" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$STOP_LABEL" 2>/dev/null || true
    rm -f "$AGENTS/$START_LABEL.plist" "$AGENTS/$STOP_LABEL.plist"
    echo "已卸载定时任务"
    ;;
status)
    for label in "$START_LABEL" "$STOP_LABEL"; do
        if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
            echo "== $label"
            launchctl print "gui/$(id -u)/$label" | grep -E "state =|next fire|runs =|last exit code" | sed 's/^[[:space:]]*/   /'
        else
            echo "== $label 未加载"
        fi
    done
    ;;
*)
    echo "用法: $0 install|uninstall|status" >&2
    exit 2
    ;;
esac
