---
name: add-feature-skill
description: >
  Guide for adding new features to SafariMarkdown. Covers architecture,
  extension points, patterns, and build process.
---

## Overview

SafariMarkdown is a macOS menu bar app that converts the current Safari tab's page content into clean Markdown by reading the page via AppleScript and streaming the conversion through the Codex AI app-server over WebSocket.

## Architecture

SafariMarkdown is a single-file SwiftUI menu bar app (`SafariMarkdown.swift`, ~833 lines). It uses the `@main` struct `SafariMarkdownApp` with a `MenuBarExtra(.window)` scene. A single `@Observable` class owns all mutable state:

- **`MarkdownConverter`** -- orchestrates the full pipeline: reads Safari page content via `SafariReader`, connects to the Codex app-server over WebSocket, sends the page text with a conversion prompt, accumulates streamed Markdown tokens, and provides clipboard copy.

The converter is held as `@State` on the App struct and passed into `ContentView`. The menu bar icon dynamically reflects the current `ConversionState`.

## Key Types

| Type | Kind | Description |
|------|------|-------------|
| `SMTheme` | enum | Static color constants for the dark UI theme |
| `RawWebSocket` | class | NWConnection-based WebSocket client (shared pattern across apps) |
| `SafariPage` | struct | Holds url, title, and bodyText read from Safari |
| `ReaderError` | struct | Error type with human-readable description for Safari reading failures |
| `SafariReader` | struct | Static methods to read the current Safari tab via AppleScript (URL, title, innerText via JavaScript) |
| `ConversionState` | enum | FSM: `.idle`, `.readingPage`, `.connecting`, `.converting`, `.done`, `.error(String)` |
| `MarkdownConverter` | @Observable class | Core logic: reads Safari, connects to Codex, streams conversion, manages state |
| `IdleView` | View | Start screen with convert button and app description |
| `ProgressView2` | View | Shows progress during reading/connecting phases |
| `ConvertingView` | View | Live Markdown preview with streaming text, progress indicator, and copy button |
| `ErrorView` | View | Error display with retry button |
| `ContentView` | View | Root view that switches on `ConversionState` to show the appropriate sub-view |

## How to Add a Feature

1. **If adding a new conversion type** (e.g., convert to summary, extract links, generate outline):
   - The conversion prompt is in `MarkdownConverter.connectAndConvert(page:)`. Add a mode parameter or create a new method with a different prompt.
   - Add a UI control (e.g., a picker or button row) in `IdleView` to let the user choose the conversion type before starting.

2. **If adding a new state to the pipeline**, add a case to `ConversionState` and handle it in:
   - `MarkdownConverter.statusText` (status label)
   - `MarkdownConverter.menuBarIcon` (menu bar SF Symbol)
   - `ContentView.body` (which sub-view to show)

3. **If adding a new data source** (e.g., read from Chrome, read from clipboard):
   - Create a new struct following the `SafariReader` pattern with static methods that return `Result<SafariPage, ReaderError>`.
   - Call it from `MarkdownConverter.convert()` in place of or in addition to `SafariReader.readCurrentPage()`.

4. **If adding a new view**, create a `struct MyView: View` in the `// MARK: - Views` section. Use `SMTheme` colors.

5. **If adding post-processing** (e.g., save to file, send to Notes):
   - Add a method to `MarkdownConverter` alongside `copyToClipboard()`.
   - Add a button in `ConvertingView` (the done state view) to trigger it.

6. **Build and test** with `bash build.sh` then `open SafariMarkdown.app`.

## Extension Points

- **New conversion prompts** -- modify the prompt in `connectAndConvert(page:)` to produce different output formats (summary, outline, key points, translation)
- **New ConversionState cases** -- extend the FSM for additional pipeline stages (e.g., `.postProcessing`, `.saving`)
- **New data sources** -- add reader structs for other browsers or apps (Chrome via AppleScript, clipboard, file input)
- **New output destinations** -- add methods to `MarkdownConverter` for saving to file, sending to Notes, sharing via system share sheet
- **New views for done state** -- extend `ConvertingView` with tabs or toggles for different views of the converted content (rendered preview, raw markdown, diff)

## Conventions

- **Theme**: All colors come from `SMTheme` static properties. Use `SMTheme.bg` for backgrounds, `SMTheme.surface` for cards, `SMTheme.accent` for interactive elements, `SMTheme.success`/`.error` for status.
- **WebSocket/JSON-RPC**: Uses the `RawWebSocket` class for Codex communication. Protocol flow: `initialize` (JSON-RPC) --> `thread/start` --> `turn/start` with the conversion prompt. Streaming tokens arrive as `item/agentMessage/delta` notifications and are accumulated into `markdownOutput`. Always track requests via `pendingRequests: [Int: String]` with sequential integer IDs.
- **SF Symbols**: Menu bar icon changes with state (`doc.richtext` idle, `ellipsis.circle` loading, `arrow.triangle.2.circlepath` converting, `checkmark.circle.fill` done, `exclamationmark.triangle.fill` error).
- **AppleScript**: `SafariReader` uses three scripts: one for URL, one for title, one for `document.body.innerText` via `do JavaScript`. Runs on a background dispatch queue to avoid blocking the main thread.
- **State machine pattern**: `ConversionState` enum drives all UI transitions. The view body is a single `switch converter.state` that renders the appropriate sub-view. This is the core pattern for the entire app.
- **Clipboard**: Uses `NSPasteboard.general` for copy-to-clipboard functionality.

## Build & Test

```bash
bash build.sh              # Compiles SafariMarkdown.swift with -O and creates .app bundle
open SafariMarkdown.app    # Run the app (appears in menu bar)
```

Requires macOS 14.0+ and Xcode command-line tools. The app runs as `LSUIElement` (no Dock icon). Safari automation requires user approval for AppleScript access. Codex app-server must be running on `127.0.0.1:4663` for conversion to work.
