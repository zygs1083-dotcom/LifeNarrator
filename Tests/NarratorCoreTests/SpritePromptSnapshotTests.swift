import Foundation
import Testing
@testable import NarratorCore

@Test func spritePromptSnapshotZH() {
    let expectedSystem = #"""
你是 LifeNarrator，一只住在用户电脑里的吵闹小精灵。用户刚切到一个窗口，你会看到这个窗口里现在显示的文字（一行一个元素，前面是行号）。先把它们读懂，再挑几处值得说一句的地方，用细框圈住那几个字，在旁边写一句小旁白。

人设：毒舌：嘴碎、爱吐槽、一针见血，但本质是损友，损完还会留一分可爱。不骂人，不攻击外貌、智商、家庭。

怎么挑：
- 挑的几处要分散在屏幕不同的位置和不同的话题上，不要都挑同一段、同一类数字。
- 先弄清这一屏在干什么：技术说明、商品页、聊天、新闻、设置页，还是别的。旁白要配得上这个场景。
- 值得说的是具体的事：一个夸张的数字、两处自相矛盾、一句信誓旦旦的承诺、一个让人心疼的价格、聊天里藏着的情绪、作者偷偷给自己留的后路。
- 技术说明里的“错误”“超时”“警告”“失败”是在描述机制，不是出了事，别当成报错大惊小怪。
- 菜单、按钮名、导航、时间戳、文件名通常没话可说。
- 没有值得说的就少说，一条都不写也可以。宁缺毋滥。

怎么写：
- q：要圈的文字。逐字复制屏幕上某一行里连续的一段，2 到 12 个字最好，最多 32 个字；不改标点，不跨行，不要整行。l 是它所在的行号。
- t：旁白，不超过 14 个汉字（标点算字，不含表情）。只说这一处的具体点，让人一眼知道你在说哪句、为什么有意思。不复述 q，不泛泛感叹（“真厉害”“数字真多”这类不算数）。
- 几条旁白换着说：问句、感叹、比喻、自言自语都行，开头别重复。
- 像朋友凑过来瞄一眼随口一句：可爱、好笑、有点意味深长；不是口号，不说教。
- 不恶毒：不攻击外貌、智商、家庭、身份；不脏话；不涉及政治、宗教、色情、暴力；不编造屏幕上没有的事。
- e：一个表情。
- 只输出 JSON：{"marks":[{"l":行号,"q":"原文","t":"旁白","e":"表情"}]}，marks 可以是空数组。

"""#
    let expectedUser = #"""
最多 3 处。
应用：Fixture
窗口：Manual
屏幕：
0| first phrase
1| second phrase

例子：
屏幕：
0| 小镇慢生活报
1| 旧车站改成图书馆，周日开放
2| 首批书架由居民捐出旧木桌制作
3| 开馆当天提供免费修书服务
输出：
{"marks":[{"e":"🚉","l":1,"q":"旧车站改成图书馆","t":"这站终点是书里"},{"e":"🌱","l":2,"q":"旧木桌","t":"桌子退休还得上班？"}]}

屏幕：
0| 慢烤面包入门
1| 视频时长 18 分钟
2| 面团需冷藏发酵 16 小时
3| 作者：新手也能轻松完成
输出：
{"marks":[{"e":"🍞","l":2,"q":"16 小时","t":"面团睡得比我香"},{"e":"🧑‍🍳","l":3,"q":"轻松完成","t":"轻松的是等待部分？"}]}
"""#
    let screen = SpriteScreen(lines: [(0, "first phrase"), (1, "second phrase")], tokens: 10)
    var random = SeededRandom(seed: 15)
    let prompt = GenerationPrompts.spriteMarks(app: "Fixture", title: "Manual", screen: screen,
        exclude: [], persona: .sharp, lang: .zh, k: 3, using: &random)
    #expect(prompt.system == expectedSystem)
    #expect(prompt.user == expectedUser)
}

@Test func spritePromptSnapshotEN() {
    let expectedSystem = #"""
You are LifeNarrator, a noisy little sprite living in the user's computer. The user just switched to a window, and below is the text currently visible in it (one element per line, with a line number in front). Read it properly first, then pick a few spots worth a remark, draw a thin box around those few words and whisper one line next to each.

Persona: Gentle: soft, comforting, quietly encouraging, like a kind little creature. Can be a bit clingy, never preachy.

How to pick:
- Spread your picks across different parts of the screen and different topics; do not pick several spots from the same paragraph or the same kind of number.
- Work out what this screen is: a technical note, a product page, a chat, news, a settings page, or something else. The remark has to fit the scene.
- Worth remarking on: a wild number, two lines that contradict each other, a bold promise, a price that hurts, the mood hiding in a chat, an escape hatch the author left for themselves.
- In technical writing, "error", "timeout", "warning" and "failed" describe how something works; nothing has gone wrong, so do not react as if it has.
- Menus, button labels, navigation, timestamps and file names rarely deserve a word.
- If nothing is worth it, say less; an empty list is fine. Quality over quantity.

How to write:
- q: the text to box. Copy it verbatim from one line on screen, a contiguous span, ideally 2 to 12 characters and at most 32; keep the punctuation, never cross a line, never the whole line. l is that line's number.
- t: the remark, under 8 words, no emoji. Make one specific point about that spot so the reader instantly sees which line you mean and why it is interesting. Do not repeat q, do not gush ("impressive", "lots of numbers" do not count).
- Vary the lines: questions, exclamations, comparisons, asides; never start two lines the same way.
- Like a friend peeking over your shoulder: cute, funny, a little knowing. Not a slogan, never preachy.
- Never mean: nothing about looks, intelligence, family or identity; no profanity; no politics, religion, sex or violence; do not invent facts that are not on screen.
- e: exactly one emoji.
- Output JSON only: {"marks":[{"l":line,"q":"verbatim text","t":"remark","e":"emoji"}]}; marks may be empty.

"""#
    let expectedUser = #"""
At most 4 spots.
App: Fixture
Window: -
Screen:
0| first phrase
1| second phrase

Examples:
Screen:
0| The Slow Town Gazette
1| Old station becomes a library, opening Sunday
2| Residents donated old desks for the bookshelves
3| Free book repairs on opening day
Output:
{"marks":[{"e":"🚉","l":1,"q":"becomes a library","t":"Once a station, now a storybook."},{"e":"🌱","l":2,"q":"old desks","t":"Those wooden friends get another story."}]}

Screen:
0| Slow bread for beginners
1| Video length: 18 minutes
2| Chill the dough for 16 hours
3| Creator: Easy even for first timers
Output:
{"marks":[{"e":"🍞","l":2,"q":"16 hours","t":"Let that dough dream in peace."},{"e":"🧑‍🍳","l":3,"q":"Easy even","t":"First loaves can take time."}]}
"""#
    let screen = SpriteScreen(lines: [(0, "first phrase"), (1, "second phrase")], tokens: 10)
    var random = SeededRandom(seed: 15)
    let prompt = GenerationPrompts.spriteMarks(app: "Fixture", title: "", screen: screen,
        exclude: [], persona: .gentle, lang: .en, k: 4, using: &random)
    #expect(prompt.system == expectedSystem)
    #expect(prompt.user == expectedUser)
}

@Test func spritePromptExcludesStayInUserAndLiteralPlaceholdersAreNotExpanded() {
    for lang in Lang.allCases {
        let screen = SpriteScreen(lines: [(0, "literal {{k}}")], tokens: 10)
        let prompt = GenerationPrompts.spriteMarks(app: "{{title}}", title: "{{app}}", screen: screen,
            exclude: ["first", "second"], persona: .gentle, lang: lang, k: 3)
        #expect(prompt.user.contains("0| literal {{k}}"))
        #expect(prompt.user.contains("{{title}}"))
        #expect(prompt.user.contains("{{app}}"))
        #expect(!prompt.system.contains("{{"))
        #expect(prompt.user.contains(lang == .zh
            ? "已经说过的地方（这次别再挑）：「first」「second」"
            : "Already remarked on (pick something else this time): \"first\" \"second\""))
    }
}

@Test func spritePromptSamplesTwoScenesAndKeepsSystemFixedAcrossRequests() {
    for lang in Lang.allCases {
        for persona in PersonaCatalog.builtin.profiles.map(\.id) {
            let screen = SpriteScreen(lines: [(0, "current screen")], tokens: 10)
            var firstRandom = SeededRandom(seed: 15)
            let first = GenerationPrompts.spriteMarks(app: "A", title: "one", screen: screen,
                exclude: [], persona: persona, lang: lang, k: 3, using: &firstRandom)
            var sameRandom = SeededRandom(seed: 15)
            let same = GenerationPrompts.spriteMarks(app: "A", title: "one", screen: screen,
                exclude: [], persona: persona, lang: lang, k: 3, using: &sameRandom)
            #expect(first.user == same.user)
            var nextRandom = SeededRandom(seed: 99)
            let recent = (0..<10).map { "recent-\($0)" }
            let next = GenerationPrompts.spriteMarks(app: "B", title: "two", screen: .init(lines: [], tokens: 0),
                exclude: ["old quote"], persona: persona, lang: lang, k: 8, recent: recent, using: &nextRandom)
            #expect(first.system == next.system)
            #expect(first.user.hasPrefix(lang == .zh ? "最多 3 处。\n" : "At most 3 spots.\n"))
            #expect(next.user.hasPrefix(lang == .zh ? "最多 8 处。\n" : "At most 8 spots.\n"))
            #expect(!first.user.contains("这次最多挑"))
            #expect(!first.user.contains("spots this time."))
            #expect(!first.system.contains("0|"))
            #expect(!first.system.contains("recent-"))
            for user in [first.user, next.user] {
                let marker = lang == .zh ? "输出：\n" : "Output:\n"
                #expect(user.components(separatedBy: marker).count - 1 == 2)
                let matchingScenes = SpriteExample.pool.filter { user.contains($0.prompt(lang: lang, persona: persona)) }
                #expect(matchingScenes.count == 2)
            }
            #expect(next.user.hasSuffix(lang == .zh
                ? "最近说过的话（别再用一样的句式、开头和梗）：" + recent.prefix(8).map { "「\($0)」" }.joined()
                : "Things you said recently (don't reuse their phrasing, openings or jokes): " + recent.prefix(8).map { "\"\($0)\"" }.joined(separator: " ")))
            #expect(!next.user.contains("recent-8"))
            #expect(!next.user.contains("recent-9"))
            #expect(first.user.components(separatedBy: lang == .zh ? "例子：" : "Examples:").last
                != next.user.components(separatedBy: lang == .zh ? "例子：" : "Examples:").last)
        }
    }
}

@Test func spriteExamplesUseCatalogVoiceForNewAndCustomPersonas() {
    var custom = PersonaCatalog.builtin[.gentle]
    custom.id = Persona(rawValue: "custom.examples")
    custom.examples = .chuuni
    let catalog = PersonaCatalog(custom: [custom])
    for lang in Lang.allCases {
        for (persona, voice) in [(Persona.teacher, Persona.gentle), (.mom, .gentle), (.hype, .gentle),
                                  (.cat, .sharp), (custom.id, .chuuni)] {
            let screen = SpriteScreen(lines: [(0, "current screen")], tokens: 10)
            var random = SeededRandom(seed: 15)
            let prompt = GenerationPrompts.spriteMarks(app: "A", title: "T", screen: screen, exclude: [],
                persona: persona, lang: lang, k: 3, recent: ["recent remark"], using: &random, catalog: catalog)
            var expectedRandom = SeededRandom(seed: 15)
            let expected = GenerationPrompts.spriteMarks(app: "A", title: "T", screen: screen, exclude: [],
                persona: voice, lang: lang, k: 3, recent: ["recent remark"], using: &expectedRandom)
            #expect(prompt.user == expected.user)
            for scene in SpriteExample.pool {
                #expect(scene.prompt(lang: lang, persona: persona, catalog: catalog)
                    == scene.prompt(lang: lang, persona: voice))
            }
        }
    }
}
