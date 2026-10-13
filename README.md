# LifeNarrator

**English** | [简体中文](README.zh-CN.md)

> Your life, now with a narrator.

LifeNarrator is a small macOS menu bar app with a noisy little sprite living in it. Every time you switch windows, the sprite reads what is on screen, circles the bits worth a remark with a thin, bright frame and whispers a cheeky line next to each one.

- A product page says "$50 off" → *"Was it ever not on sale?"*
- Your boss's chat is open → their name gets boxed with *"Pig Boss 🐷"*
- Tell it *"I hate Google"* once → it grumbles every time Google shows up.

![A boxed name and a "Pig Boss" line on a test chat window](docs/images/boss-bubble.png)

> **Status:** v0.6 preview. Download `LifeNarrator.zip` from [Releases](https://github.com/zygs1083-dotcom/LifeNarrator/releases).

## Features

- **Reads before it speaks.** With a model, the sprite reads the visible text, works out what you are looking at, picks a few spots, and writes a line about each one. It circles the exact words it is talking about; if it cannot find them on screen, it says nothing.
- **Right on the text.** Frames sit on the words, lines go into empty space nearby, and both follow the window when it moves. Each mark gets a random light, bright color.
- **Knows when to be quiet.** Nothing while you type, in password fields, over full-screen video, or in apps you exclude. The same spot is not marked twice within half an hour.
- **Your own rules.** Press ⌥⇧N and describe what you love or hate in plain words, e.g. "I hate meetings" or "Zhang San is my boss". Rules always fire first.
- **Easy to tune.** Liveliness (quiet / lively / rowdy) decides how much it says; sliders set the gap between marks, how long each one stays and how many share the screen. Shapes, colors, fonts, emoji and three personas (snarky, sweet, chuunibyou) are all adjustable.
- **Works without a model.** An offline quip pack covers popular apps and websites, and only confident spots (your rules, chat names, prices, buttons, deadlines) are marked.
- **Bring your own model.** Download the built-in engine (Qwen3.5-4B, 2.7 GB) after install, or connect any OpenAI-compatible API or local server (Ollama, LM Studio).
- **Bilingual.** English and Simplified Chinese interface and lines.

## Lightweight and private

- Event-driven: when nothing changes on screen, it does nothing. Idle, it uses about 22 MB of memory and 0% CPU (M1 Max).
- Text is read through the Accessibility API; screen capture and on-device OCR are used only for wrapped text that has no exact position.
- With the built-in model, the first mark appears about 3–5 seconds after a switch. At most 4 requests a minute, none in Low Power Mode; a request stops as soon as you switch away, and the model is unloaded after 10 idle minutes.
- Everything stays on your Mac by default. Screen text is never logged or saved, input fields and password fields are never sent, and emails, phone numbers and URLs are removed before the model sees anything. If you connect a cloud API, the settings say clearly what is sent.

## Requirements

- macOS 14 Sonoma or later on Apple silicon
- Accessibility permission (required); Screen Recording permission (optional, used for OCR)

## Install

1. Download `LifeNarrator.zip` from [Releases](https://github.com/zygs1083-dotcom/LifeNarrator/releases), unzip it and move `LifeNarrator.app` to Applications.
2. The app is not signed with an Apple Developer ID. On macOS 14, right-click it and choose **Open**. On macOS 15 or later, open it once, then click **Open Anyway** in **System Settings → Privacy & Security**.
3. Pick a model in the welcome window and grant Accessibility permission.

LifeNarrator lives in the menu bar and has no Dock icon. **⌥⇧N** adds a rule, **⌥⇧P** pauses the sprite. If the menu bar is too full to show the icon (common on MacBooks with a notch), open LifeNarrator again from Applications or Spotlight to bring up its settings.

Releases are signed with the same self-signed certificate since v0.1.4, so the Accessibility permission survives updates. Coming from an older version, remove LifeNarrator from **Privacy & Security → Accessibility** and add it again once.

## Build from source

```sh
swift build
swift test
scripts/bundle.sh   # needs Xcode; builds dist/LifeNarrator.app and dist/LifeNarrator.zip
```

## License

[MIT](LICENSE)
