# T19 Windows 技术验证报告

## 改了什么

基于 `origin/main` 的 `452761f`（0.8.1），新增跨平台 `narrator-brain` 可执行目标、纯 JSON-RPC 处理函数与测试；新增 .NET 8 / Avalonia 11 的四模式验证程序、Linux 无头像素验收程序，以及 Windows / Linux CI。

未修改 NarratorCore 或 Mac 源码。新主线的 `HTTPStream`（URLSessionDataDelegate）、人格、SaidHistory、供应商目录和 Updates 均参与 Windows 编译与核心测试。

依赖选择：Avalonia 11.3.10；UIA 选择 `Interop.UIAutomationClient` 10.19041.0，直接调用系统 COM 接口即可完成元素和 TextPattern 读取，无需 FlaUI 包装层。无其他直接第三方依赖；Avalonia.Skia 用于无头真实像素渲染。无头测试是独立可执行验收程序，断言失败返回非零退出码，无额外测试框架。

协议、命令与产物说明见 [README](README.md)。

## 怎么验证的

**[最终 CI：全部通过](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38774733539)**，验证代码提交 `1ffd93c`。产物：[Windows 四模式与发布文件](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38774733539/artifacts/11993616552)、[Linux 气泡 PNG](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38774733539/artifacts/11993775373)。

| 验证点 | 结论 | 证据与边界 |
| --- | --- | --- |
| Swift 核心及 HTTPStream | 可行 | Windows Swift 6.2 编译通过，145 个测试通过（143 Core + 2 brain），无需修改 NarratorCore |
| stdio brain | 可行 | `brain.json`：UTF-8 中文规则命中，返回 work / lineIndex 0，ping 9.54 ms、matchRules 7.10 ms，EOF 后退出码 0；移除全局 Swift PATH 后仍通过 |
| Avalonia 浮层 | 可行，有样式生命周期坑 | `overlay.json`：五个扩展样式均为 true，透明级别 Transparent，前台焦点保持；截图核对见 overlay.png |
| Edge UIA | 可行 | `uia.json` 与 uia-edge.png：中文、英文正文和 TextPattern 行矩形均可读，与截图文字行位置吻合：英文 (62,136,402,27)，中文 (62,200,264,27)；测试带强制可访问性参数 |
| 经典记事本 UIA | 有坑 | 中英文全文可读，但编辑框不提供 TextPattern；ValuePattern 矩形为整个编辑框 (138,181,752,437)，不能据此做逐字高亮 |
| Windows.Media.Ocr | 可行，语言受限 | `ocr.json`：仅 en-US，返回 40 行 / 281 个英文背景词及物理像素坐标；中文气泡识别质量未验证 |
| Linux Avalonia 无头渲染 | 可行 | headless-linux 通过，真实 Skia 像素断言与 bubble-headless.png；中文描边和彩色 emoji 显示正常 |

CI 冷启动总历时 **7 分 33 秒**（包括排队/初始化/上传）；Windows job **7 分 28 秒**。Windows 核心编译 64 秒、swift test 52 秒、Release 构建 76 秒、运行库收集 29 秒、外壳发布 51 秒、四模式合计 17 秒。其余 job：core-linux 67 秒、headless-linux 37 秒、macos 249 秒。

### 体积（Release，未压缩）

| 内容 | 字节 | MiB |
| --- | ---: | ---: |
| narrator-brain.exe | 4,125,696 | 3.93 |
| Swift 及相关运行库 DLL | 58,791,888 | 56.07 |
| Core 资源 | 681,543 | 0.65 |
| brain 完整目录 | 63,599,127 | 60.65 |
| .NET 8 自包含外壳（217 文件） | 123,542,293 | 117.82 |
| 两者合计 | 187,141,420 | 178.47 |

运行库收集包含实际 PE 导入闭包中的 Swift、Foundation、ICU、VC/UCRT DLL，未复制整个 SDK。`_FoundationICU.dll` 为 35,854,336 字节，是主要体积项。完整文件清单见 `brain-size.json`，外壳测量见 `shell-size.json`。CI 的 windows-spike ZIP 为 76,096,926 字节，包含两套发布文件、测试 fixture、JSON、截图和日志；它不是安装包。

### 命令与结果

本机 Linux：

- `swift test`：143 个 NarratorCore 测试、2 个 brain 测试通过；本机 Swift 6.4，CI 使用 Swift 6.2。
- `~/.dotnet/dotnet run --project windows/LifeNarrator.HeadlessTests`：通过，生成 `artifacts/bubble-headless.png`，检查实际粉色填充像素；已人工查看中文描边和彩色 emoji。
- `~/.dotnet/dotnet build windows/LifeNarrator.Windows --no-restore`：Windows 交叉编译通过，0 warning / 0 error。
- `printf` 多行请求送入 `.build/debug/narrator-brain`：`ping` 返回核心版本，未知方法返回 `-32601`。
- `git diff --check`：通过。

Windows CI 的检查命令：`swift build --target NarratorCore`、`swift test`、`swift build -c release --product narrator-brain`、`windows/scripts/package-brain.ps1`、`dotnet publish windows/LifeNarrator.Windows -c Release -r win-x64 --self-contained true -o artifacts/shell`、`windows/scripts/run-spikes.ps1`。

### 坑和处理

1. **Swift CoreFoundation 模块**：Windows Swift 6.2 不公开此模块。brain 的 JSON-RPC ID 校验改用 Foundation 的 NSNumber 类型信息区分布尔值和数值。NarratorCore 本身没有需要 `#if os(Windows)` 修补的不兼容点。
2. **stdio 文本模式**：Windows brain 将 stdin/stdout 设置为 CRT binary 模式，避免换行转换影响逐行 UTF-8 协议；EOF 正常退出，错误使用 JSON-RPC 响应，stdout 只输出协议。
3. **Avalonia 覆盖扩展样式**：单次 SetWindowLongPtr 会在显示窗口时被 Avalonia 重算样式覆盖。改为 `Win32Properties.AddWindowStylesCallback` 保留标志，显示后调用 SetLayeredWindowAttributes。验收读取真实 HWND 样式与显示前后前台窗口，不以属性声明代替实际结果。
4. **Windows PE 工具定位**：Swift setup 没有把 dumpbin 加进 PATH；runner 又有多个 MSVC 工具版本。用系统 vswhere 找到并选择一个 dumpbin，递归解析 PE 导入并收集运行库。brain 验证时移除 PATH 中的 Swift 目录，防止借用全局安装掩盖缺失 DLL。
5. **UIA provider 差异**：runner 是经典 Win32 记事本，编辑框不提供 TextPattern。ValuePattern 可取得完整文本，但矩形是整个编辑框，不能冒充逐行可见范围。Edge 提供正文元素和 TextPattern 行矩形；测试使用强制可访问性参数与独立临时 profile。
6. **OCR 语言**：runner 只安装 en-US。系统 OCR 调用和英文文字坐标可验证，中文旁白的识别质量不能从本次结果推出；没有偷偷使用另一种 OCR 引擎。

## 遗留问题和 W1 建议

- 先按 T20 抽取跨平台引擎，再扩展 brain 协议承载 W1 的引擎状态与生成调用。本次只验证 ping / RuleMatcher，延迟数据不代表模型生成性能。
- 外壳可沿用本次样式回调与物理屏幕坐标约定。W1 需在 Windows 真机验证跨屏、125%/150% 缩放、滚动及真实鼠标穿透；runner 只有一个 1024×768、100% 缩放屏幕。
- UIA 优先使用 TextPattern 行矩形，ValuePattern 结果保留“全文/控件矩形”语义。普通已运行的 Edge、Chrome、Electron 是否启用可访问性仍需真机验证，不能把带启动参数的测试视为通用保证。
- W1 的 UIA 采集应放到不拥有窗口的独立 MTA 线程，避免桌面遍历影响 Avalonia UI。依据：[Microsoft UIA 线程说明](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading)。
- W2 验证中文 OCR 前，需要带中文 OCR 语言包的 Windows 测试环境；当前只证明系统英文 OCR API 可调用。
- 运行库和自包含 .NET 都计入安装体积。W1 打包需携带 Swift DLL/资源和相应 VC runtime；本次没有制作安装包，也没有验证一台未安装开发工具的个人 Windows 电脑。

所有改动提交并推送到 `zygs1083-dotcom/windows-spike`，由总控复核后决定合并。
