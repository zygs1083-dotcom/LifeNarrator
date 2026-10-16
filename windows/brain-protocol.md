# Brain stdio 协议（T20b / W1）

`narrator-brain` 托管一个 `SpriteBrain`。每行一条 UTF-8 JSON-RPC 2.0 对象，stdout 仅输出协议，stderr 输出日志。Windows stdin/stdout 使用 CRT binary 模式。关闭 stdin（EOF）正常退出，退出码 0；传输失败、畸形回复或不可抛错端口的调用失败会终止会话，退出码 1，原因写 stderr。无 batch、无自动重试。

## 收发与顺序

请求为 `{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}`；成功回复为 `{"jsonrpc":"2.0","id":1,"result":...}`；错误回复为 `{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"...","data":...}}`（data 可省略）。id 可以是字符串或数值，也接受 null；建议外壳使用递增整数。无 id 的通知不产生回复。params 可省略为 `{}`；下面各方法使用具名对象参数。

大脑向外壳发出的每次端口调用都有字符串 id：`brain:1`、`brain:2`……。两端的请求 id 各自独立。外壳**必须持续读取 stdout 并处理端口请求**，不能在等某个事件的回复时停止分发。大脑也会发送没有 id 的 `host.stateChanged` 通知；外壳处理后不得回包。多个请求可同时在路上，回复可乱序，以 id 配对。事件按收到的行顺序交给大脑；事件回复只表示已接收，生成、传感器访问和显示会在之后异步发生。被取消请求的迟到回复忽略。

外壳发给大脑的 `layout.*` 请求可在处理 `overlay.show` 时发起，等待布局结果后再回复 `overlay.show`，无需另开会话。`ping` 和 `layout.*` 不要求先 configure。

## 公共类型

- 字段名保持以下 camelCase 拼写，包括 `windowID`、`ownProcessID`、`trackID`、`baseURL`；`bundleId`、`quipID`、`ruleID` 同下文。
- `Rect = {x:number,y:number,w:number,h:number}`；`Size = {w:number,h:number}`；`Window = {frame:Rect,chromeHeight:number}`。几何数值有限，尺寸非负。
- 坐标为统一的屏幕坐标系，左上角为原点、x 向右、y 向下，可有负数。单位使用与 Mac pt 对应的**逻辑单位**；Windows 外壳负责 UIA/截图物理像素和 DPI 单位转换。一次布局中的窗口、屏幕可见区、锚点、行、占用区、障碍物必须处于同一坐标系。大脑不做 DPI 转换。
- `Range = {location:integer,length:integer}`：零起始，**所在行文字的 UTF-16 单元**偏移，绝非全文偏移或 Unicode 字符数；`lineIndex` 为 snapshot.textLines 的零起始下标。
- 日期是 ISO 8601 字符串，例如 `2026-10-16T08:00:00Z`；大脑输出 UTC、秒精度。时间区间单位为秒。
- 可选对象字段允许省略或 null；大脑编码可选字段时可能省略。可选的顶层 result 必须显式用 `"result":null`。无返回值的方法 result 也是 null。
- `Persona` 是字符串：内置 `sharp/gentle/chuuni/teacher/mom/hype/cat`，自定义 `custom.*`。
- `RectKind = "bounds" | "estimated" | "ocr"`；kind 可选时表示未指定来源。

## 外壳 → 大脑

### configure

参数（完整替换配置，不是补丁）：

```json
{
  "settings": {
    "liveliness": "lively", "markGap": 2, "paused": false,
    "blacklist": [], "persona": "gentle", "lang": "zh",
    "disabledBuiltinIds": [], "maxOnScreen": 3, "ownProcessID": 1234, "memoryEnabled": true,
    "systemOne": null
  },
  "rules": [], "customPersonas": [],
  "generator": {"kind":"none"},
  "dataDirectory": "C:\\LifeNarrator\\data"
}
```

result：null。首次成功时创建数据目录并载入 `said.json`，启动大脑；后续 configure 复用同一个大脑和说过的话历史。dataDirectory 为大脑进程可访问的本机路径，同一会话不能更换，需重启进程。失败配置不替换正在使用的配置。

settings 的必填项即上例除 systemOne 外的字段。liveliness 为 `quiet/lively/rowdy`，markGap ≥ 0，maxOnScreen > 0，lang 为 `zh/en`，ownProcessID 为外壳进程的 Int32 pid。memoryEnabled 为是否让小精灵记住事情（关掉时不记、不用，已有记忆保留）。blacklist 为字符串数组，disabledBuiltinIds 为规则 id 数组。modelAvailable 由生成器是否存在计算，不从外壳读取。可选 systemOne 为 `{baseURL:string,model:string,key:string}`，baseURL 必须是 http(s) URL，使用现有 SystemOneClient。

rules 使用 NarratorCore 的 Rule：必填 `{id,kind,source,enabled,label,sentiment,match,highlight,quips}`；可选 `input,note,variables,createdAt`。label 为 `{zh,en}`，variables 为字符串字典，createdAt 为日期；kind 为 `app/site/person/topic/time`，source 为 `user/builtin`，sentiment 为 `dislike/like/neutral`。match 的可选字段为 `bundleIds,appNames,domains,aliases`（字符串数组）、region（`header/anywhere`）、when（`any/lateNight/mondayMorning/fridayEvening`）。app 要有 bundleIds 或 appNames，site 要有 domains，person 要有 aliases 和 region，topic 要有 aliases，time 要有非 any 的 when。Quip 为 `{lang,persona,text,emoji?:string[],when?:string}`，emoji 默认 []，when 默认 any。W1 应始终传上面的必填项。

customPersonas 是完整 PersonaProfile 数组：`{id,emoji,name,caption,description,focus?,limit,fonts,pack,examples}`。name/caption/description/focus 为 `{zh:string,en:string}`；limit 固定 `{zh:14,en:8}`；fonts 为 `{zh:string[],en:string[]}`；id 必须是唯一的 `custom.*`；pack/examples 必须为 `sharp/gentle/chuuni` 之一。settings.persona 必须存在于内置和自定义目录中。内置规则和离线台词由大脑的 Core 资源加载，无需外壳传输。

生成器三种形态：

- `{"kind":"none"}`：只使用离线规则和台词。
- `{"kind":"api","presetId":"openai","model":"MODEL","key":"KEY","baseURL":"https://example.com/v1","structured":"json_schema"}`：presetId、model、key 必填，baseURL 和 structured 可省略，沿用 preset。model 不可为空，baseURL 必须为 http(s) URL。structured 为 `json_schema/json_object/prompt`。presetId 使用 `Sources/NarratorCore/Resources/providers.json` 中的 id；通过 ProviderConfiguration / ProviderCatalog 构造 OpenAIChatClient 或 AnthropicClient。Anthropic 沿用其工具结构化输出，不使用 OpenAI 的 structured 选项。key 允许空字符串（本地免鉴权服务）；不写入数据目录，也不输出到日志。
- `{"kind":"builtin","modelPath":"C:\\LifeNarrator\\models\\model.gguf"}`：macOS / Windows 上使用本机 GGUF 模型和 GBNF 约束生成。modelPath 必填且必须指向进程可访问的文件；缺失、空路径或文件不存在返回 -32602。首次生成时加载模型，空闲 10 分钟释放；重新配置会关闭旧生成器，configure 的成功回复会等待旧生成任务结束和旧模型释放（期间仍处理端口回复），宿主收到后可删除旧 GGUF；新模型等待旧模型释放后加载，EOF / 会话失败退出前也释放。Windows 使用官方 llama.cpp b11429 CPU 后端，有可用 Vulkan 设备时自动卸载到 GPU；Mac 仍使用 Metal。模型加载或生成失败经 host.report 暴露。Linux 不编译 NarratorLlama，builtin 返回 -32001。下载及选择模型由宿主负责，本协议不提供下载功能。

### testConnection

参数：`{generator:{kind:"api",presetId:string,model:string,key:string,baseURL?:string,structured?:string}}`。
通过现有生成器发送一个最小 JSON 请求（`{"ok":true}`），验证响应并返回 `{elapsedMilliseconds:number}`。
不要求 configure，不替换当前配置，也不使用屏幕文字。调用异步执行，等待时仍处理其他 RPC。
配置错误返回 -32602；请求失败或响应无效返回 -32003。会话关闭时取消未完成的测试。

### chat.send / chat.history

`chat.send` 参数：`{text:string,narration?:string,includeScreen:bool}`。text 不可为空；narration 是点击旁白时附带的文字。result 为 `ChatTurn = {id:UUID字符串,user:string,reply:string,notice?:string}`，notice 为首次记忆隐私提示。`chat.history` 参数 `{}`，result 为最近最多 50 轮的 `ChatTurn[]`。对话存于数据目录的 `chat.json`。

大脑从最近的外部窗口 snapshot 生成上下文，复用 `SpriteBrain.chatContext` 的密码焦点、黑名单和隐私过滤；外壳不传原始 screen/title。只在 includeScreen=true 时附上过滤后的屏幕文字。外壳打开聊天窗口时应默认取消勾选。生成异步执行，期间继续分发 RPC（包括 host 端口及其嵌套 configure/rules.compile）。模型未配置、生成失败、无效意图、宿主操作失败返回 -32004，不伪造回复；外壳保留输入并展示错误。

### memory.list/add/edit/pin/delete/clear

| 方法 | params | result |
| --- | --- | --- |
| memory.list | `{}` | Memory[] |
| memory.add | `{kind,text}` | 新 Memory，近似重复或 memoryEnabled=false 时 null |
| memory.edit | `{id,kind,text}` | null |
| memory.pin | `{id,pinned:bool}` | null |
| memory.delete | `{id}` | null |
| memory.clear | `{}` | null；保留用户规则和聊天记录 |

`Memory = {id:UUID字符串,kind:"fact"|"preference"|"nickname"|"episode",text:string,source:"chat"|"stats"|"manual",createdAt:date,lastUsedAt:date,uses:integer,pinned:bool}`。手动添加的 source 固定为 manual，text 沿用大脑的 1–40 字约束。编辑、置顶和删除的未知 id 返回 -32602，参数或文字无效返回 -32602，文件 IO 失败返回 -32000。总开关由 configure.settings.memoryEnabled 控制；关掉时已有记忆可查看、编辑和删除，但不会新增或参与生成。记忆保存在 `memory.json`。

### growth.state / growth.setName

`growth.state` 参数 `{}`，result：

```
{
  "state": {"firstMetAt":"...", "activeDays":1, "consecutiveDays":1,
    "narrations":0, "chatMessages":0, "rulesLearned":0, "personasTried":["gentle"],
    "experience":30, "level":1, "unlocked":[], "...":"其余 GrowthState 统计字段"},
  "name":"", "title":"刚孵出来", "daysKnown":0,
  "nextLevelExperience":160,
  "unlocks":[{"id":"spriteName","level":2,"name":"给小精灵起名字"}, "..."]
}
```

state 沿用 `GrowthState` 编码；称号、认识天数、解锁等级和名称均由大脑计算，使用 configure 的语言。满级时 nextLevelExperience 省略或 null。unlocked 为 `spriteName/emoji/starBubble/catchphrase/greetings/starryTheme/oldFriend` 的集合。

`growth.setName` 参数 `{name:string}`，result null；Lv.2 前返回 -32602。名字首尾去空白，空字符串表示使用人格名。Windows 的名字保存在同一数据目录的 `sprite-name.json`；原有成长数字仍存 `growth.json`。更新后发 host.stateChanged。外壳只能在对应 unlocked 项存在时启用名字、扩展表情、星星形状和星空主题。

### rules.compile

参数 `{input:string}`，result 为 configure.rules 使用的 `Rule`。供处理 `host.saveRule` 的 Windows 宿主嵌套调用；复用 Core 的 RuleCompiler 和当前生成器，不保存、不自行计经验。Windows 应持久化规则并带完整规则数组重新 configure，然后回复 host.saveRule；成功后 RPC 宿主适配器记录一次 rule 成长事件。Windows 应用匹配沿用 appNames（不解析 Mac bundle id）。编译失败返回 -32004。

### snapshot

参数：`{snapshot:ContextSnapshot,windowID:uint32,change:{appChanged:bool,windowChanged:bool,hostChanged:bool}}`。result：null。

ContextSnapshot 必填字段：`bundleId:string,appName:string,pid:int32,windowFrame:Rect,contentFrame:Rect,screenIndex:integer,textLines:TextLine[],textSource:string,sensitiveRects:Rect[],secureFocused:bool,fullScreen:bool,capturedAt:date`。可选 `windowTitle,url,host` 为字符串。textSource 为 `ax/ocr/none`，TextLine 为 `{text:string,rect:Rect,role?:"text"|"button"|"link"|"field"}`（role 默认 text）。OCR 更新也通过 snapshot 回传。传感器端口必须针对外壳最新快照的行回答。

### windowFrameChanged

参数：`{frame:Rect}`，result：null。通知当前窗口移动/缩放。

### windowChanged

参数：`{}`，result：null。当前窗口失效/切换时取消旧窗口工作；随后传新 snapshot。

### ping

参数：`{}`，result：`{version:string}`，值为 NarratorCore.version。

### layout.sizeTier

参数：`{requested:"small"|"medium"|"large",window:Window}`。
result：`"small" | "medium" | "large" | null`，直接来自 `BubblePlacement.sizeTier`。null 表示窗口太小，不应显示。外壳先获取档位，再按该档位测量气泡。

### layout.place

参数：

```json
{
  "size":{"w":180,"h":44}, "narrowSize":{"w":160,"h":60},
  "anchor":{"x":400,"y":400,"w":40,"h":18}, "line":null,
  "window":{"frame":{"x":200,"y":100,"w":800,"h":600},"chromeHeight":52},
  "visibleFrame":{"x":0,"y":25,"w":1440,"h":800},
  "occupied":[], "obstacles":[], "inkInset":{"w":0,"h":0}, "stackSizes":[]
}
```

size 是已测量的气泡**完整外框**尺寸（含绘制留白、尾巴等），narrowSize 是外壳按窄版测量的尺寸，可省略/null。尺寸必须为正。anchor 是原始命中文字矩形，和 Narration.anchor 相同；**不要预先扩张**。大脑按 Mac 的 `spriteFrame` 扩张 x 两侧各 5、y 两侧各 3 得到 highlight，再调用 `anchoredSprite`。line 可省略/null，默认 highlight。occupied 包含已有气泡外框及高亮框；obstacles 为不希望遮盖的文字墨迹矩形。inkInset 为文字样式的透明留白，非负；其他样式传零。

anchor 省略/null 时，调用 `appStack(sizes:[size]+stackSizes)`。stackSizes 为**同窗口已有角落气泡**的外框尺寸，按新到旧排列，当前新气泡不含在内。无锚点分支不使用 narrowSize、line、occupied、obstacles、inkInset 的布局值。外壳应先调用 sizeTier 判断窗口是否可显示。

result 无位置时为 null；否则为：

| 字段 | 类型及含义 |
| --- | --- |
| frame | Rect，气泡外框位置与所选测量尺寸 |
| highlight | Rect?，扩张后的锚点框；角落模式无此字段 |
| side | `above/below/right/left`?；角落模式无此字段 |
| narrow / covered / connector / outside | bool，直接来自 SpritePlacement；角落模式全为 false |
| corner | `topRight/topLeft`?，仅角落模式 |
| stackFrames | `(Rect|null)[]`?，仅角落模式，首项是新气泡，后续对应 stackSizes；null 项表示移除该旧气泡 |
| placement | `right/lineEnd/above/below/rightMargin/leftMargin/outsideRight/outsideLeft/covered/corner`，可原样回传 overlay.show 的 placement |

covered 时 Mac 会改圆角、取消旋转、使用 0.92 填充并重新测量；本方法返回的是传入测量尺寸对应的布局，外壳负责同样的样式处理/测量与绘制。connector 是是否需要连接，不含平台绘图数据。布局算法始终复用 NarratorCore，无 C# 副本。

## 大脑 → 外壳（端口请求）

除下文 host.stateChanged 通知外，端口方法均带 id，外壳必须回复 result 或 error。无参数时 params 为 `{}`。不支持的方法也必须回复 -32601。

| 方法 | params | result |
| --- | --- | --- |
| sensor.isTyping | `{now:date}` | bool |
| sensor.isSecureFocused | `{}` | bool |
| sensor.idleSeconds | `{}` | number，任意输入事件后的空闲秒数 |
| sensor.lastTypedAt | `{}` | date，最近打字时间 |
| sensor.isLowPowerMode | `{}` | bool |
| sensor.refresh | `{}` | null |
| sensor.boundsProbe | `{}` | bool |
| sensor.startVisualLines | `{}` | null；开始后台 OCR，结果另发 snapshot |
| sensor.textRect | `{lineIndex:integer,range:Range}` | `{rect:Rect,kind:RectKind}` 或 null |
| sensor.markTrack | `{lineIndex:integer,kind?:RectKind}` | string 跟随句柄或 null |
| sensor.unframedRect | `{lineIndex:integer,range:Range}` | Rect |
| sensor.placementLine | `{lineIndex:integer,rect:Rect,kind?:RectKind}` | Rect |
| sensor.placementObstacles | `{contentFrame:Rect}` | Rect[] |
| overlay.show | `{narration:Narration}` | `{shown:bool,placement:string}` |
| overlay.dismissAll | `{}` | null |
| overlay.follow | `{}` | null |
| overlay.highlight | `{id:string}` | Rect 或 null |
| overlay.windowFrameChanged | `{windowID:uint32,window:Window}` | null |
| host.saveRule | `{input:string}` | null；编译、持久化、configure 成功后才回复 |
| host.applySetting | `{setting:{liveliness?:string,paused?:bool,persona?:string}}` | null；按非 null 字段更新本地设置、保存并 configure 后回复 |
| host.report | `{error:{code:integer,message:string,data?:any}}` | null |

`host.stateChanged` 是 **无 id 通知**，params `{}`，不回包。记忆、成长数字、名字或人格配置变化时触发；外壳重新读取 memory.list / growth.state，更新已打开的界面和托盘名字/Lv。通知不携带屏幕文字或 API key。

Narration 必填：`id:string,quipID:string,ruleID:string,sequence:integer,text:string,emoji:string[],language:"zh"|"en",persona:Persona,framed:bool,obstacles:Rect[],windowID:uint32,window:Window`；可选 `anchor:Rect,line:Rect,trackID:string`。id 标识本次气泡实例，quipID 标识台词，ruleID 标识规则；trackID 是外壳给 markTrack 的不透明句柄，大脑原样转发给浮层。framed 控制文字框装饰；即使 false，仍可有 anchor 供定位。

sensor.isTyping、isSecureFocused、boundsProbe、textRect、markTrack 的错误会抛回 SpriteBrain，由其现有错误处理通过 host.report 报告。其他端口在 Swift 协议中不能抛错，其 error 或无法解码的 result 会终止整个会话，绝不伪造成功/默认值。host.report 对远端 BrainRPCError 保留 code/message/data；其他引擎错误 code 为 -32000。

## 错误码与 T19

- -32700：JSON 解析错误；-32600：无效请求；-32601：未知方法；-32602：参数/配置错误。
- -32004：聊天、规则编译或宿主意图执行失败。
- -32000：数据目录、记忆、成长、名字或历史文件 IO 错误；-32001：builtin 不支持；-32002：事件之前尚未 configure。
- 可抛错端口保留外壳返回的错误码。错误通知不产生回复。

T19 `matchRules` 仍供旧验证程序调用：参数 `{snapshot:ContextSnapshot,rules:Rule[]}`，result 为 `[{ruleId:string,lineIndex:integer|null}]`。**仅此旧入口**沿用 Foundation 的 CGRect 数组 `[[x,y],[w,h]]`，日期 ISO 8601；每个 snapshot 按 appChanged/hostChanged 匹配，时间取 capturedAt。W1 使用本页的新事件与矩形对象格式。
