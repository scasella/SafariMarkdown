# SafariMarkdown

Convert the current Safari tab to clean Markdown with one click, powered by Codex.

## Why it exists

You're reading an article, docs page, or blog post in Safari and want it as clean Markdown — for notes, LLM context, or documentation. Instead of copy-pasting messy HTML or using a browser extension, SafariMarkdown reads the page content via AppleScript, sends it to a local Codex app server, and streams back well-structured Markdown in real-time.

## Requirements

- macOS 26+
- Safari with "Allow JavaScript from Apple Events" enabled (Safari > Settings > Advanced > check "Show features for web developers", then Developer menu > Allow JavaScript from Apple Events)
- [Codex app server](https://github.com/openai/codex) running locally: `codex-app-server --listen ws://127.0.0.1:8080`

## Install

```bash
cd SafariMarkdown

# Compile
swiftc -parse-as-library -o SafariMarkdown SafariMarkdown.swift

# Build .app bundle (hides dock icon)
mkdir -p SafariMarkdown.app/Contents/MacOS
cp SafariMarkdown SafariMarkdown.app/Contents/MacOS/

cat > SafariMarkdown.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SafariMarkdown</string>
    <key>CFBundleIdentifier</key>
    <string>com.dailywidgets.safarimarkdown</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SafariMarkdown needs access to Safari to read the current page content.</string>
</dict>
</plist>
EOF

# Launch
open SafariMarkdown.app
```

## Quickstart

1. Start the Codex app server: `codex-app-server --listen ws://127.0.0.1:8080`
2. Open any web page in Safari
3. Click the **MD** icon in your menu bar
4. Click **Convert Current Page**
5. Watch Markdown stream in real-time
6. Click **Copy** to copy to clipboard

## How it works

1. Reads the current Safari tab's URL, title, and body text via AppleScript
2. Connects to the local Codex app server over WebSocket
3. Creates an ephemeral thread with `gpt-5.3-codex-spark` at medium effort
4. Sends the page content with instructions to extract main content and format as Markdown
5. Streams the response in real-time with a monospaced text display
6. Disconnects when done — no persistent connections

## Examples

**Convert a blog post:**
Open any blog post in Safari → click MD → click Convert → get clean Markdown with proper headings, code blocks, and links.

**Convert documentation:**
Open API docs or library docs → convert → paste into your notes or feed to an LLM as context.

**Convert a news article:**
Open a news article → convert → get just the article content without ads, nav, comments, and sidebars.

**Partial copy during streaming:**
Click Copy at any time during conversion to grab whatever has been generated so far.

**Cancel and retry:**
Click Cancel during conversion, or Try Again on error.

## Menu bar states

| Icon | State |
|------|-------|
| `MD` (doc.richtext) | Idle — ready to convert |
| `...` (ellipsis) | Reading page or connecting |
| `↻` (arrows) | Converting — streaming in progress |
| `✓` (checkmark) | Done — conversion complete |
| `⚠` (warning) | Error — see popover for details |

## Troubleshooting

**"Safari is not running"** — Open Safari and navigate to a page first.

**"Could not read page content"** — Enable JavaScript from Apple Events:
Safari > Settings > Advanced > Show features for web developers > then Developer menu > Allow JavaScript from Apple Events.

**"Could not connect to Codex server"** — Start the server:
`codex-app-server --listen ws://127.0.0.1:8080`

**"Page content is empty"** — The page may be a PDF, image, or still loading. Wait for it to finish loading and try again.

**Content is truncated** — Pages over 60,000 characters are truncated to stay within model context limits. The truncation point is noted in the output.

## Architecture

Single-file SwiftUI app (~550 lines):
- `RawWebSocket` — raw TCP WebSocket client (avoids `Sec-WebSocket-Extensions` rejection)
- `SafariReader` — NSAppleScript wrapper for Safari tab access
- `MarkdownConverter` — @Observable state machine managing the full conversion lifecycle
- `ContentView` — MenuBarExtra with state-driven sub-views

## License

MIT
