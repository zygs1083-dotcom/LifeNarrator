# LifeNarrator

**English** | [简体中文](README.zh-CN.md)

> Your life, now with a narrator.

LifeNarrator is a lightweight macOS menu bar app that watches what is on your screen and pops up small, cute narration bubbles on the active window: colorful hand-drawn fonts, a few emoji, and a lot of attitude.

- Open DingTalk → *"Back to work again! 😩"*
- Open a chat with your boss → their name gets boxed with *"Pig Boss 🐷"*
- Tell it *"I hate Google"* once → every time you open Google, it grumbles for you.

> **Status:** early development. Nothing is ready to install yet.

## Features (planned for v0.1)

- **Real-time, on the active window**: bubbles appear next to the window you are using, or right on the text they are talking about, and follow the window when it moves.
- **Your own rules**: a global input box (hotkey) where you describe what you love or hate in plain words, e.g. "I hate meetings", "Zhang San is my boss". LifeNarrator turns them into rules and reacts when they come up on screen.
- **Fully customizable bubbles**: display time, fade and pop animations, how many bubbles at once, size, shape (bubble, cloud, speech balloon, sticker, sticky note), art text effects, color themes, emoji density, persona (snarky, sweet, chuunibyou).
- **Works without any AI model**: a built-in quip pack covers popular apps and websites.
- **Bring your own model**: download the built-in engine after install, or connect any OpenAI-compatible API or local server (Ollama, LM Studio). Fast decisions use [System One](https://docs.typesafe.ai/concepts/system-one) models such as Jev or open alternatives through the `/v1/systemone` API.
- **Bilingual**: English and Simplified Chinese UI and quips.

## Lightweight by design

- Event-driven: when nothing changes on screen, it does nothing.
- Reads text through the Accessibility API first. Screen capture and on-device OCR are used only when needed, and skipped when the window has not changed.
- Quips are generated ahead of time and cached, so bubbles appear instantly without waiting for a model.
- No bundled models or fonts. It uses the cute fonts that already ship with macOS.
- Targets: under 80 MB of memory without a model loaded, and near-zero CPU when idle.

## Privacy

Everything runs on your Mac by default. Screen text is never logged or saved to disk, and password fields are never read. If you connect a cloud API, the app tells you clearly that screen text will be sent to it.

## Requirements

- macOS 14 Sonoma or later
- Apple silicon
- Accessibility permission (required) and Screen Recording permission (optional, enables OCR for apps that do not expose their text)

## Building from source

```sh
swift build
scripts/bundle.sh   # builds dist/LifeNarrator.app and dist/LifeNarrator.zip
```

Releases are not signed with an Apple Developer ID yet. The first time you open the app, right-click it and choose **Open**.

## License

To be decided.
