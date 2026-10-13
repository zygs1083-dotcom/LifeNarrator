import Foundation
import NarratorCore

struct SpriteCase: Sendable {
    let id: String
    let lang: Lang
    let text: String

    var snapshot: ContextSnapshot {
        var y = 100.0
        let lines = text.components(separatedBy: "\n").map { text in
            let width = text.unicodeScalars.reduce(0.0) { $0 + ($1.value >= 0x2E80 ? 14 : 7) }
            let height = ceil(width / 680) * 22
            defer { y += height + 12 }
            return TextLine(text: text, rect: CGRect(x: 40, y: y, width: min(width, 680), height: height))
        }
        return ContextSnapshot(bundleId: "fixture.sprite-bench", appName: "Sprite Bench", pid: 0,
            windowTitle: id, windowFrame: CGRect(x: 0, y: 0, width: 760, height: 820),
            contentFrame: CGRect(x: 24, y: 80, width: 712, height: 716),
            textLines: lines, textSource: .ax, capturedAt: Date(timeIntervalSince1970: 0))
    }
}

let spriteCases = [
    SpriteCase(id: "zh-technical", lang: .zh, text: """
    预览索引器运行说明
    索引器只读取本地草稿，为搜索面板生成预览，不会修改原文件。
    1. 每 8 秒检查一次待处理队列，每轮最多取 24 份草稿。
    2. 处理超过 6 秒记为超时，草稿会回到队尾等待下一轮。
    3. 超时不是错误，连续 7 轮超时才显示警告，用于提醒检查草稿大小。
    当一份草稿同时包含大量插图与长表格时，索引器会先完成文字部分，再分批补齐插图标题，因此搜索结果可能先有文字后有图片，这属于设计中的处理顺序，警告也不表示原文件已损坏。
    4. 单份草稿上限 18MB，超过上限只索引前 12 页。
    测试集平均完成时间 2.6 秒，最慢的一份用了 5.9 秒。
    面板显示完成进度 100% 后，缩略图仍可能等待下一轮刷新。
    暂停按钮会保留队列，恢复后从未完成的草稿继续。
    """),
    SpriteCase(id: "zh-product", lang: .zh, text: """
    云朵桌面暖杯垫
    把午后的热茶留到下一场会议。
    售价 ¥268，绒布收纳袋另加 ¥39。
    三档温度：42 度、50 度、58 度。
    宣传承诺：一整天都像刚泡好。
    连续工作 90 分钟后自动关闭，需手动重新开启。
    适合平底陶瓷杯，不适合双层隔热杯。
    首批 600 件已预订 587 件。
    赠送杯垫贴纸，茶杯仅作展示不随货附送。
    预计 16 天后发货，礼盒包装再加 2 天。
    """),
    SpriteCase(id: "zh-chat", lang: .zh, text: """
    周末纸飞机展筹备群
    小禾：我把海报颜色改成了浅蓝，应该够安静了吧。
    阿桥：挺安静的，就是标题像在小声求救。
    小禾：那我只把标题放大，不再改第九版了。
    阿桥：刚才那张其实是第十一版。
    小禾：文件夹已经比展览内容丰富了。
    阿桥：报名桌准备好了，还差一支能写的笔。
    小禾：我带了 30 架纸飞机，忘带笔了。
    阿桥：没关系，先让飞机负责吸引人。
    小禾：好，今天争取让海报比我们早下班。
    """),
    SpriteCase(id: "en-technical", lang: .en, text: """
    Thumbnail queue design note
    The worker reads draft boards and writes disposable previews.
    1. Poll the queue every 9 seconds and take up to 16 boards.
    2. A timeout after 5 seconds returns the board to the queue.
    3. A timeout is not an error; a warning appears after 8 attempts.
    Large boards publish text previews first and add image tiles in later passes, so a complete text preview can still have empty image slots while the worker follows its normal schedule.
    4. Boards above 22MB receive previews for the first 15 panels only.
    The trial average was 1.7 seconds; the slowest board took 4.95 seconds.
    Progress can read 100% while image tiles are still waiting.
    Pausing keeps pending boards; resuming does not restart finished panels.
    """),
    SpriteCase(id: "en-product", lang: .en, text: """
    Pocket Meadow desk lamp
    A little sunrise for your reading corner.
    Price: $84, with a travel sleeve sold separately for $18.
    Three brightness levels and a swiveling paper shade.
    Our promise: a full week between charges.
    Battery test: 7 days at 12 minutes of use per day.
    Maximum brightness runs for 95 minutes on one charge.
    Only 14 of the first 420 lamps remain available.
    The wooden stand in the pictures is a display accessory.
    Ships in 19 days; gift wrapping adds another 3 days.
    """),
    SpriteCase(id: "en-chat", lang: .en, text: """
    Rooftop sketch club
    Mina: I packed everything for our drawing session.
    Theo: Even the pencils this time?
    Mina: Twelve pencils, two erasers, and a very serious folding chair.
    Theo: The forecast says rain in twenty minutes.
    Mina: Then we have nineteen minutes to become fast artists.
    Theo: We could just draw from the cafe window.
    Mina: Fine, but the chair has been looking forward to this all week.
    Theo: Bring it. It can supervise the pastries.
    Mina: Finally, a leadership role it can handle.
    """),
]
