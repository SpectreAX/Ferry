# Ferry

A lightweight, native macOS Markdown editor built with SwiftUI and AppKit (TextKit 1), designed for copying text and inline images cleanly into desktop AI apps (Claude, ChatGPT, Codex, Antigravity, etc.).

## Features

- **Inline Images & Lossless Markdown**: Renders local images inline with `ImageAttachment` while preserving original Markdown syntax on save (`MarkdownCodec`), and stores imported images in a document-adjacent `assets/` folder (`AssetStore`).
- **Live Syntax Highlighting**: Incremental CommonMark + GFM styling (`SyntaxHighlighter`) that never alters text and avoids restyling during IME composition, paired with Return list/task/quote continuation (`ListContinuation`).
- **Hide Markdown Syntax (`⇧⌘M`)**: Toggle hiding Markdown syntax symbols in the editor (`View` menu or `Ferry › Settings`), revealing the active cursor paragraph automatically without changing document text (`SyntaxHider`).
- **Ignore Markdown Syntax When Copying**: Optional toggle (`Edit` menu or `Ferry › Settings`) to strip Markdown syntax for external apps (`MarkdownStripper`) while keeping lossless Markdown when pasting back into Ferry and via `⌥⌘C`.
- **Rich Paste Import**: Preserves reading order of text and images from RTFD (Notes, Pages, TextEdit) and HTML (browsers, Notion, Word) via `RichClipboardReader` and `PasteImporter`, downloading remote web images in the background (`RemoteImageLoader`).
- **Three Copy Modes for Mixed Selections** (`Ferry › Settings`):
  - **Paste twice** *(default)*: Offers image files lazily on the first paste, then swaps the clipboard to text with `[Image N]` placeholders for the second paste (`TwoStepClipboard`).
  - **Paste once (.md + images)**: Attaches text as a `.md` file alongside image files for Chromium/Electron apps that ignore clipboard text when files are present (`FerryPasteboard` + `ClipboardAttachments`).
  - **One ⌘V (experimental)**: Uses Accessibility (`CGEventTap` + background `AXUIElement` observation) to paste images one at a time, confirm each in the target UI, and then paste the text — never presses Return, never drops content, and learns per-app behavior (`AppPasteRules`).
- **Plain Markdown Copy**: `⌥⌘C` copies plain relative-path Markdown directly to the clipboard.

## Project Structure

- `Ferry/App`: App entry point, `ReferenceFileDocument`, main editor window, toast, and settings UI.
- `Ferry/Editor`: TextKit 1 editor (`EditorTextView`), SwiftUI wrapper (`MarkdownEditor`), inline image attachment cell, and syntax highlighter.
- `Ferry/Model`: Markdown codec, asset store, pasteboard read/write, rich clipboard reader, remote image loader, list continuation, and two-step clipboard.
- `Ferry/Paste`: One ⌘V state machine (`OnePasteMachine`), controller, event tap, keystroke poster, AX observer/snapshot, attachment counter, and per-app rules.
- `FerryTests`: Unit tests covering Markdown syntax/codec, rich paste, copy/paste, two-step clipboard, app rules, attachment counting, and the One ⌘V state machine/controller.
- `design/`: App icon SVG masters, Icon Composer layers, and PNG previews.
- `scripts/`: Asset helper scripts (`make_icon.swift`).

## Building & Testing

### Requirements

- macOS 14.0+
- Xcode 15+
- Zero third-party Swift dependencies
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate `Ferry.xcodeproj` from `project.yml`, and `librsvg` (`rsvg-convert`) if running `swift scripts/make_icon.swift`.

### Build & Test

`project.yml` specifies a local `DEVELOPMENT_TEAM`; when building locally, override `DEVELOPMENT_TEAM` or adjust signing in Xcode / `project.yml` if needed:

```sh
xcodebuild -project Ferry.xcodeproj -scheme Ferry test CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```
