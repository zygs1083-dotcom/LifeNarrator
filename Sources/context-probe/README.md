# context-probe（macOS）

`swift run context-probe` 请求辅助功能和录屏权限；辅助功能授权后需重新运行。
每个快照向 stdout 输出一行 JSON，包含快照、变化原因、候选、UTF-16 命中范围和高亮矩形。
规则来自内置 `quips.json`，另加一条 `header` 区域的 person「张三」。无文件输出。

`ContextSensor` 的 `onSnapshot` 同时提供 `appChanged`、`hostChanged`；`reason` 按应用、host、内容的优先级给出原因。
`onWindowFrame` 只更新窗口位置与尺寸，不触发文本读取。
`preciseRect(lineIndex:range:)` 的行号和范围对应最近一次快照；返回 nil 时用 `RuleMatcher.estimatedRect`。
外部 API 的错误交给 `onError`，probe 遇到错误退出并打印到 stderr。

## Fixture 真机检查

SwiftPM 裸可执行文件没有 bundle identifier，按设计感知层会忽略此类前台进程。
在项目/worktree 内包装 Fixture，再用 `open` 启动（无需安装或操作个人应用）：

```sh
swift build --product NarratorFixtures
mkdir -p .dev-data/NarratorFixtures.app/Contents/MacOS
cp "$(swift build --show-bin-path)/NarratorFixtures" .dev-data/NarratorFixtures.app/Contents/MacOS/
cat > .dev-data/NarratorFixtures.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.lifenarrator.fixtures</string>
<key>CFBundleExecutable</key><string>NarratorFixtures</string>
<key>CFBundleName</key><string>NarratorFixtures</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - .dev-data/NarratorFixtures.app
open .dev-data/NarratorFixtures.app
swift run context-probe
```

- 切到 `Fixture Chat`：窗口标题不含人名，右侧 17pt「张三」应命中 person；左侧列表与预览不应作为 header。
- 切到 `Fixture Group`：正文提到「张三」，应无 person 候选；切换「图片内容（OCR）」后应看到 `textSource: ocr`。
- 切到 `Fixture Document`：应读取到「明天下午开会」。
- 移动／缩放窗口只应收到 frame 回调；用调用方检查，不应新增 probe 快照。
- 在新开的浏览器测试窗口验证 Safari `AXDocument`、Chromium `AXURL`、Firefox `AXURL`／`AXDocument` 和 address 文本框回退；host 去掉 `www.`、转小写。
- 检查授权前后的 AX/OCR 路径、Retina／多屏坐标、AX 子串精确矩形、同窗口相同 dHash 复用及移动后的 OCR 坐标。

Firefox 的属性差异和各应用的通知支持仍需真机确认。dHash 是 64 位感知哈希，细小文本变化可能碰撞；按 T4 要求，相等时直接复用。
