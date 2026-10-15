# W2b：Windows 内置 GGUF 引擎

## 改了什么

已按总控要求 rebase 到 `origin/main` 的 `89612b9`（W1b/W3/W4 + 等待与聊天 schema 修复），丢掉分支上重复的等待修复。`testConnection`、其事件等待测试和四组大脑测试的 `.timeLimit(.minutes(1))` 均保留。

- LlamaEngine / LlamaGenerator / LlamaGrammar 从 NarratorMac 移到 NarratorLlama，只依赖 NarratorCore 和 llama C 库。GeneratorMetrics、聊天 schema 常量下移到 Core；ChatEngine.schema 保留原入口。
- NarratorMac 依赖并重新导出 NarratorLlama，继续使用原 b11429 XCFramework / checksum。Metal 要求、采样参数、串行队列、空闲 600 秒释放和 malloc 回收调用保持原行为。Windows 用 NSLock 和基于 DispatchQueue 的 SerialExecutor；没有新增 Swift 包依赖。
- RPC 接受 `generator:{kind:"builtin",modelPath:"..."}`，缺少 / 空路径 / 非文件返回 -32602。首次生成加载 GGUF，重新配置关闭旧模型，新模型等待旧模型释放；EOF / 会话失败在 await close 完成后退出。加载或生成错误经原 host.report 暴露。
- 正常 SwiftPM 配置仅在 macOS / Windows 声明 NarratorLlama，Linux CI 不下载、不编译它。未做 Windows 下载、对话或记忆界面。

### llama 接入方式和理由

使用 [llama.cpp 官方 b11429](https://github.com/ggml-org/llama.cpp/releases/tag/b11429)，与 Mac 完全同版。

| 包 | SHA-256 |
| --- | --- |
| llama-b11429-bin-win-cpu-x64.zip | 1283323272b04cd07905816a597a0da810918102de958f4ff6f7bbaa70ed2efe |
| llama-b11429-bin-win-vulkan-x64.zip | 1bfe78ad9168b79fa02bf67f6af9f5e17a966d824d77238517f7bef12ac73b36 |

采用 **固定目录下载 + SwiftPM system library/module map**：官方 Windows ZIP 只有 DLL，没有头文件与导入库；`setup-llama.ps1` 下载同一提交 `d81235049384534c167caea52b85a694f6103d14` 的 7 个 C 头文件，逐一校验 SHA-256，再用 MSVC dumpbin/lib 从已校验 DLL 的导出表生成导入库。没有编译第三方源文件，不依赖机器预装 llama 或 Vulkan SDK。所有下载和生成文件都在 gitignore 的 `.dev-data/llama`，预编译包不进仓库。

Windows 从已加载 llama.dll 所在目录注册动态后端，选择适合当前 CPU 的变体；检测到 GPU offload 支持则 n_gpu_layers=-1，否则为 0。打包目录移动后仍可发现后端。`package-brain.ps1` 显式收集 CPU 变体、Vulkan 和 OpenMP（这些不都出现在 PE 导入表里），之后递归收集导入闭包，附带 llama MIT / OpenMP 许可证。Vulkan loader 由显卡驱动提供，缺少它时 CPU 路径仍可用。

## 第 0 条：偶发超时的原因和独立修复

[T21b 失败记录](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38792032969) 中 RPC 场景在 7.381 秒时触发固定 4 秒轮询期限。它与聊天、记忆、成长测试共享 MainActor，后者包含同步文件持久化；旧期限从事件入队后开始，包含其他测试占用 actor 的时间，可能在协议任务有机会派发 overlay.show 前就过期。

独立提交 `590f72c2dc343fbcacff80338e6437353fc6bfd0` 已先推送并交给总控，随后被挑入 main。它把 RPC 和 SpriteBrain 的正向等待改为测试替身的缓冲 AsyncStream 事件，覆盖请求发出、生成器启动/取消、几何暂停、浮层和错误端口；不增加 timeout / sleep / 重试，不改生产时序。

[独立修复 CI 38801399223 全绿](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38801399223)。同一 Windows runner、同一 RPC 场景：**单独运行 0.231 秒；全量并行运行 5.537 秒**，都通过。这个对照确认了共享 actor 排队与测试绝对期限的冲突，场景本身没有固定的数秒等待。另一次修复后的 RPC 场景甚至在 53.482 秒后通过，而同轮仍用 3 秒轮询的 SpriteBrain 用例失败，故一起移除了该 helper 的轮询。总控后来加的 1 分钟 suite 保护用于防止事件永远不到时挂住 CI，本分支没有改它。

## 怎么验证的

本机 Linux：

- rebase 后 `swift test`：48 个 XCTest、161 个 Core Swift Testing 测试、48 个 Brain 测试通过，包含 W1b 连接测试。
- `python3 -m py_compile windows/scripts/check-builtin-model.py`、`git diff --check` 通过。

最终代码提交为 `62db02e707123947bda541649e1103c34d8e4a3b`；[CI 38814293413](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38814293413) **四个 job 全绿**：Windows、macOS、core-linux、headless-linux。Windows 的 release 构建、打包目录独立运行、真实模型 RPC、shell 端到端、安装/卸载、从旧版本应用内更新检查均通过。

最终 Windows `swift test` 为 48 个 XCTest 和 209 个 Swift Testing 测试通过；RPC 场景单独 **0.192 秒**、全量并行 **5.040 秒**，事件等待均通过。

同版 main 基线为 `89612b9`，[CI 38813481133 全绿](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38813481133)。该 artifact 的 brain 目录为 **67,525,777 字节（64.40 MiB）**，其中 exe 为 7,669,760 字节。体积不含 GGUF。

| 项目 | main 89612b9 | W2b | 增量 |
| --- | ---: | ---: | ---: |
| brain 目录 | 67,525,777 B（64.40 MiB） | 138,259,940 B（131.85 MiB） | 70,734,163 B（67.46 MiB） |
| narrator-brain.exe | 7,669,760 B | 7,967,744 B | 297,984 B |

新增 llama DLL 与许可证共 **70,436,179 B（67.17 MiB）**，其中 Vulkan 后端为 45,305,344 B（43.21 MiB）。其余目录增量恰为 exe 增量；Swift 运行库没有扩包。文件清单与模型结果见 [windows-spike artifact](https://github.com/zygs1083-dotcom/LifeNarrator/actions/runs/38814293413/artifacts/12010687217)。

Mac CI 保留原 GGUF 测试入口：7 个 LlamaEngine 测试因未设置 NARRATOR_TEST_MODEL 按原逻辑跳过，6 个 LlamaGrammar 测试执行通过，90 个 XCTest（7 skipped）与 209 个 Swift Testing 测试无失败，完整 App 构建/打包通过。未操作用户的个人 Mac。

### Windows 真实模型与耗时

固定模型：[unsloth/Qwen3.5-0.8B-GGUF](https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/tree/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0)，revision `6ab461498e2023f6e3c1baea90a8f0fe38ab64d0`，`Qwen3.5-0.8B-Q4_K_M.gguf`，532,517,120 字节，SHA-256 `bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517`。CI 缓存文件且每次检查哈希。

**夹具边界**：最终 snapshot 包含一行测试短语和内置示例中被标记的 22 行英文自然文本，关闭离线规则干扰。它验证真实 GGUF 推理、GBNF、RPC、定位和显示的集成，**不用于评估语义泛化质量**。开发探针观察到小模型复述提示词尾部示例的引文，孤立事实也会合法返回空数组。为遵守“不改 Mac 行为”，没有调整共享提示词或采样参数，而把引擎集成夹具与这个现有语义问题分开。示例文本与实际 snapshot 有意重叠，故不能从通过结果推导新屏幕上的正确率。最终仍使用最初的轻量 0.8B 模型，没有加入重试或放宽生产 20 秒首条期限。

检查命令：`python windows/scripts/check-builtin-model.py artifacts/brain/narrator-brain.exe $env:NARRATOR_TEST_MODEL`。脚本移除 PATH 中 Swift / llama 全局目录，仅用打包目录运行，通过 configure / snapshot / 传感器回复 / overlay.show 验证带锚点的 sprite-model 标记、整批 reason=ok 和 EOF 退出 0。夹具为英文示例自然文本列表加一行测试短语、普通毒舌人格，显示上限 8、请求 k=8（使用已有高上屏配置的鼓励多选行为）。没有放宽模型输出或定位校验，也没有自动重试。

最终 Windows runner 从打包目录加载 `ggml-cpu-icelake.dll`，模型各层分配到 CPU；prompt prefill 为 6.228 秒。首条 **12.522 秒**，整批 **13.089 秒**，marks=1 / located=1 / shown=1，reason=ok，EOF 退出码 0。真实生成文本为 “The button text looks like a joke.” 🤡，带屏幕锚点并经过 overlay.show 回复确认。

首条是通过 SpriteGenerator 校验后的首个标记；整批是请求结束时间。这些时间来自生产请求日志，包含模型加载、prompt prefill 和 GBNF 生成，是单次测量，不是纯 token 解码速度或 P95。真实日志和结果保存在 windows-spike artifact 的 `builtin-model-test/` 下，完整文件清单为 `brain-size.json`。

## 遗留问题

现有小模型会复述提示词示例，未见屏幕上的语义质量尚需单独验证；本次夹具不能证明该能力。Windows x64 CPU 已完成真实加载和生成；Vulkan 后端已随包提供，但 runner 没有可用 Vulkan GPU，尚无真机 GPU 性能数据。Windows 模型下载 UI 留待第二部分。Mac 的真实 GGUF 集成测试仍需要有模型的环境。
