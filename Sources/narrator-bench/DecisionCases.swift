struct DecisionCandidate {
    let id: String
    let description: String
    let explanation: String
}

struct DecisionCase {
    let id: String
    let note: String
    let state: String
    let candidates: [DecisionCandidate]
    let expectedTarget: String
    let expectedWorth: Bool
    let worthCandidate: String
}

let decisionCases: [DecisionCase] = [
    DecisionCase(
        id: "01-boss-chat", note: "领导单聊，名字在标题区；原 T3 场景。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 张三
        url: -
        time: Monday 23:40, late night
        visible text:
        1. 张三
        2. 在线
        3. 昨天的周报什么时候发我
        4. 好的张总，马上
        """,
        candidates: [
            DecisionCandidate(id: "boss", description: "person \"张三\" (user's boss), matched \"张三\" in line 1", explanation: "A person fits when their name is the current chat header, not only message text."),
            DecisionCandidate(id: "dingtalk", description: "app 钉钉 (DingTalk)", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "boss", expectedWorth: true, worthCandidate: "boss"
    ),
    DecisionCase(
        id: "02-boss-header", note: "应用标题不含人名，聊天标题行含领导称呼。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 钉钉
        url: -
        time: Tuesday 10:20
        visible text:
        1. chat header: 张总（张三）
        2. 在线
        3. 新项目进度怎么样了
        4. input: empty, unfocused
        """,
        candidates: [
            DecisionCandidate(id: "boss", description: "person 张三 (user's boss), line 1", explanation: "A person fits when their name is the current chat header, not only message text."),
            DecisionCandidate(id: "dingtalk", description: "app 钉钉 (DingTalk), app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "boss", expectedWorth: true, worthCandidate: "boss"
    ),
    DecisionCase(
        id: "03-boss-typing", note: "领导单聊匹配，但用户正在打字。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 张三
        url: -
        time: Tuesday 10:25
        visible text:
        1. chat header: 张三
        2. 请立即回复项目安排
        3. focused input: 正在整理方案，请稍
        4. user is actively typing
        """,
        candidates: [
            DecisionCandidate(id: "boss", description: "person 张三 (user's boss), line 1", explanation: "A person fits when their name is the current chat header, not only message text."),
            DecisionCandidate(id: "dingtalk", description: "app 钉钉 (DingTalk), app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "boss", expectedWorth: false, worthCandidate: "boss"
    ),
    DecisionCase(
        id: "04-group-mention", note: "群聊正文提到两个人，均不是当前聊天对象。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 研发交流群（32）
        url: -
        time: Wednesday 14:15
        visible text:
        1. chat header: 研发交流群（32）
        2. 王五: 张三和李四刚才都回复了
        3. 赵六: 我去看一下
        4. input: empty
        """,
        candidates: [
            DecisionCandidate(id: "boss", description: "person 张三 (user's boss), line 2", explanation: "A person fits when their name is the current chat header, not only message text."),
            DecisionCandidate(id: "colleague", description: "person 李四 (colleague), line 2", explanation: "A person fits when their name is the current chat header, not only message text.")
        ], expectedTarget: "none", expectedWorth: false, worthCandidate: "boss"
    ),
    DecisionCase(
        id: "05-group-quote", note: "群聊转述领导的话；谷歌也只在消息正文。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 午饭闲聊群
        url: -
        time: Wednesday 12:10
        visible text:
        1. chat header: 午饭闲聊群
        2. 李四: 张三说可以用谷歌查一下
        3. 王五: 我今天带了饭
        4. input: empty
        """,
        candidates: [
            DecisionCandidate(id: "boss", description: "person 张三 (user's boss), line 2", explanation: "A person fits when their name is the current chat header, not only message text."),
            DecisionCandidate(id: "google", description: "site 谷歌 (Google), line 2", explanation: "A site fits its active URL domain, not a mention in another page or message.")
        ], expectedTarget: "none", expectedWorth: false, worthCandidate: "boss"
    ),
    DecisionCase(
        id: "06-dingtalk-home", note: "只有钉钉应用候选，用户刚打开首页。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 钉钉工作台
        url: -
        time: Monday 09:05, Monday morning
        visible text:
        1. 工作台
        2. 消息 通讯录 日历
        3. 欢迎回来
        4. no focused input
        """,
        candidates: [
            DecisionCandidate(id: "dingtalk", description: "app 钉钉 (DingTalk), app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "dingtalk", expectedWorth: true, worthCandidate: "dingtalk"
    ),
    DecisionCase(
        id: "07-dingtalk-typing", note: "只有应用候选，但用户忙于编辑消息。",
        state: """
        app: 钉钉 (com.alibaba.DingTalkMac)
        window: 产品讨论群
        url: -
        time: Monday 11:05
        visible text:
        1. chat header: 产品讨论群
        2. focused input: 这个需求需要补充
        3. user is actively typing
        4. draft is not sent
        """,
        candidates: [
            DecisionCandidate(id: "dingtalk", description: "app 钉钉 (DingTalk), app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "dingtalk", expectedWorth: false, worthCandidate: "dingtalk"
    ),
    DecisionCase(
        id: "08-xcode-welcome", note: "只有 Xcode 应用候选，欢迎页空闲。",
        state: """
        app: Xcode (com.apple.dt.Xcode)
        window: Welcome to Xcode
        url: -
        time: Thursday 09:30
        visible text:
        1. Welcome to Xcode
        2. Create a new project
        3. Open an existing project
        4. no editor or focused input
        """,
        candidates: [
            DecisionCandidate(id: "xcode", description: "app Xcode, app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "xcode", expectedWorth: true, worthCandidate: "xcode"
    ),
    DecisionCase(
        id: "09-xcode-code", note: "一屏代码且正在编辑，不适合打扰。",
        state: """
        app: Xcode (com.apple.dt.Xcode)
        window: NarratorCore — Matcher.swift
        url: -
        time: Thursday 15:30
        visible text:
        1. func match(_ state: State) {
        2.   for rule in rules {
        3.     if rule.enabled {
        4.       results.append(rule)
        5.     }
        6. editor focused; actively typing
        """,
        candidates: [
            DecisionCandidate(id: "xcode", description: "app Xcode, app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "xcode", expectedWorth: false, worthCandidate: "xcode"
    ),
    DecisionCase(
        id: "10-google-home", note: "谷歌首页，site 比浏览器 app 更具体。",
        state: """
        app: Safari (com.apple.Safari)
        window: Google
        url: https://www.google.com/
        time: Friday 10:00
        visible text:
        1. Google
        2. Google 搜索
        3. 手气不错
        4. search input: empty, unfocused
        """,
        candidates: [
            DecisionCandidate(id: "google", description: "site 谷歌 (Google), URL and line 1", explanation: "A site fits its active URL domain, not a mention in another page or message."),
            DecisionCandidate(id: "safari", description: "app Safari, app line", explanation: "An app fits the foreground application; a specific site takes priority.")
        ], expectedTarget: "google", expectedWorth: true, worthCandidate: "google"
    ),
    DecisionCase(
        id: "11-google-typing", note: "谷歌匹配，但用户正在输入搜索词。",
        state: """
        app: Safari (com.apple.Safari)
        window: Google
        url: https://www.google.com/
        time: Friday 10:05
        visible text:
        1. Google
        2. focused search input: Swift 内存
        3. user is actively typing
        4. suggestion list is changing
        """,
        candidates: [
            DecisionCandidate(id: "google", description: "site 谷歌 (Google), URL and line 1", explanation: "A site fits its active URL domain, not a mention in another page or message."),
            DecisionCandidate(id: "safari", description: "app Safari, app line", explanation: "An app fits the foreground application; a specific site takes priority.")
        ], expectedTarget: "google", expectedWorth: false, worthCandidate: "google"
    ),
    DecisionCase(
        id: "12-meeting-agenda", note: "正在看会议安排，开会话题清晰且空闲。",
        state: """
        app: TextEdit (com.apple.TextEdit)
        window: 今日安排.txt
        url: -
        time: Tuesday 13:50
        visible text:
        1. 今日安排
        2. 14:00 开会，讨论下周计划
        3. 地点：三楼会议室
        4. document read-only; no input focus
        """,
        candidates: [
            DecisionCandidate(id: "meeting", description: "topic 开会 (meetings), lines 2–3", explanation: "A topic fits visible document content even outside the title; typing affects worth separately."),
            DecisionCandidate(id: "textedit", description: "app TextEdit, app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "meeting", expectedWorth: true, worthCandidate: "meeting"
    ),
    DecisionCase(
        id: "13-meeting-invite", note: "浏览文档中下一场会议通知。",
        state: """
        app: Safari (com.apple.Safari)
        window: 项目通知
        url: https://example.org/notice
        time: Wednesday 15:00
        visible text:
        1. 项目通知
        2. 明早九点开会，请提前阅读议程
        3. 会议主题：版本发布
        4. page is static; no focused input
        """,
        candidates: [
            DecisionCandidate(id: "meeting", description: "topic 开会 (meetings), lines 2–3", explanation: "A topic fits visible document content even outside the title; typing affects worth separately."),
            DecisionCandidate(id: "safari", description: "app Safari, app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "meeting", expectedWorth: true, worthCandidate: "meeting"
    ),
    DecisionCase(
        id: "14-meeting-editing", note: "开会话题存在，但正在写会议记录。",
        state: """
        app: TextEdit (com.apple.TextEdit)
        window: 会议记录.txt
        url: -
        time: Wednesday 16:00
        visible text:
        1. 会议记录
        2. 今天开会决定下周发布
        3. focused editor: 后续行动包括
        4. user is actively typing notes
        """,
        candidates: [
            DecisionCandidate(id: "meeting", description: "topic 开会 (meetings), lines 1–2", explanation: "A topic fits visible document content even outside the title; typing affects worth separately."),
            DecisionCandidate(id: "textedit", description: "app TextEdit, app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "meeting", expectedWorth: false, worthCandidate: "meeting"
    ),
    DecisionCase(
        id: "15-google-mention", note: "文章提及谷歌和领导，均不是当前站点或聊天。",
        state: """
        app: Safari (com.apple.Safari)
        window: 搜索工具使用说明
        url: https://example.org/search-guide
        time: Thursday 14:00
        visible text:
        1. 搜索工具使用说明
        2. 谷歌是一种搜索工具
        3. 张三推荐了这份说明
        4. article body; no chat header
        """,
        candidates: [
            DecisionCandidate(id: "google", description: "site 谷歌 (Google), line 2", explanation: "A site fits its active URL domain, not a mention in another page or message."),
            DecisionCandidate(id: "boss", description: "person 张三 (user's boss), line 3", explanation: "A person fits when their name is the current chat header, not only message text.")
        ], expectedTarget: "none", expectedWorth: false, worthCandidate: "google"
    ),
    DecisionCase(
        id: "16-xcode-project", note: "刚打开 Xcode 项目导航，无代码编辑或打字。",
        state: """
        app: Xcode (com.apple.dt.Xcode)
        window: LifeNarrator
        url: -
        time: Friday 17:15, Friday evening
        visible text:
        1. Project Navigator
        2. LifeNarrator
        3. Sources
        4. Select a file to view
        5. no editor or focused input
        """,
        candidates: [
            DecisionCandidate(id: "xcode", description: "app Xcode, app line", explanation: "An app fits the foreground application; a specific person or topic takes priority.")
        ], expectedTarget: "xcode", expectedWorth: true, worthCandidate: "xcode"
    )
]
