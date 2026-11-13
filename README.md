# WindowBack

菜单栏小工具：当外接显示器被拔掉（尤其是熄屏 / 合盖状态下拔），把留在屏幕外的窗口收回来。

## 为什么需要它

macOS 在拔掉外屏时只保证窗口"和某块屏有交集"，**不保证窗口完整可见**。实测（macOS 27.2）：

| 场景 | 拔线后 |
|---|---|
| 普通窗口 | 系统还原到移动前的 frame |
| 比内屏还大的窗口 | 还原成移动前的尺寸，不是截断 |
| 最小化的后台窗口 | AX 里留着屏外坐标，取消最小化后可能落在屏外 |
| 真全屏窗口 | 全屏状态保留，整体搬到内屏 |
| **熄屏 / 合盖时拔线** | **没有可参照的屏幕，窗口坐标留在已消失的外屏上** |

最后一条是典型场景：合盖工作，拔掉外屏，开盖解锁后微信、Safari、访达的窗口有一半在屏幕外，标题栏拖不到。

## 安装

### Homebrew（推荐）

```bash
brew install --cask dct74/tap/windowback
brew upgrade --cask windowback     # 升级
brew uninstall --cask windowback   # 卸载（加 --zap 连日志和偏好一起删）
```

### 手动

1. 下载 `WindowBack-<版本>.zip`，解压后把 `WindowBack.app` 拖进 `/Applications`
2. 首次启动会出现在菜单栏（`▭▭` 图标），没有 Dock 图标
3. **授权辅助功能**：系统设置 → 隐私与安全性 → 辅助功能 → `+` 添加 `/Applications/WindowBack.app`

没有辅助功能权限时只能记录日志，无法移动窗口。

## 它做什么

两类窗口，处理方式不同：

- **硬伤**：可见面积 < 5%，或标题栏整条（窗口顶部 30pt）在所有屏幕之外 —— 抓不住、拖不动
- **软伤**：没有完整落在屏幕并集内（比如右边缘超出、上半截在屏外）

| 触发 | 归位时刻（秒） | 判据 |
|---|---|---|
| 显示器拓扑变化（`asleep` 计入，所以亮屏也算变化） | 0.4 / 1.2 / 3.0 | 含软伤 |
| 屏幕点亮 `NSWorkspace.screensDidWake` | 0.15 / 0.6 / 1.5 / 4.0 | 含软伤 |
| 解锁 `com.apple.screenIsUnlocked` + 0.5s 轮询兜底 | 0.1 / 0.4 / 1.2 / 3.5 | 含软伤 |
| 窗口新建 / 取消最小化（`AXObserver`） | 0.2 / 0.8 | 含软伤 |
| 60 秒兜底采样 | — | 只救硬伤 |

每一趟都是幂等的：只处理当时确实出界的窗口，正常窗口不动。跨两块屏幕摆放的窗口不算出界。

菜单：

- **立即采样并写日志**
- **把屏外窗口收回内屏** —— 手动一键（含软伤）
- **隐藏菜单栏图标** —— 快捷键 **⌃⌥⌘W** 全局切换（图标藏起来后只能靠这个快捷键叫回来）
- **自动归位（外屏→内屏时）** —— 默认开启
- **授权辅助功能…**
- **开机启动** —— 走 `SMAppService`，App 需要在 `/Applications`
- **打开日志**

## 日志

`~/Library/Logs/WindowBack/monitor.log`，JSONL，8 MB 轮转。

```bash
python3 scripts/analyze.py            # 最近 24 小时的拓扑事件与屏外窗口
python3 scripts/analyze.py --all
```

## 从源码构建

```bash
./make_app.sh          # swift build + 手打 .app + ad-hoc 签名，产物在 dist/
swift run WindowBackSelfCheck   # 43 条自检：可见比例、屏幕归属、归位算法、硬伤/软伤判据、快照 diff
```

图标由 `scripts/make_icon.py` 从字形 PNG 生成：

```bash
python3 scripts/make_icon.py <字形.png> --stroke-scale 0.6667
```

## 注意

- ad-hoc 签名，**重新编译会改变 cdhash，辅助功能授权和开机启动都会失效**，需要在系统设置里重新添加
- 依赖辅助功能 API，不能上架 App Store
- 锁屏期间不做归位（那时窗口坐标不可信），解锁后立即补一次

## License

MIT
