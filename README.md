<p align="center">
  <img src="StringIntoAction/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" alt="String Into Action app icon">
</p>

# String Into Action

Copyright © 2026 Made by Windmill, LLC.

Review your app’s UI copy.

String Into Action is a native macOS dev tool for finding and reviewing user-facing text in apps and web projects. It presents each string alongside its source context, lets you edit in place, and remembers exactly what you approved.

All local. String Into Action has no network features, analytics, accounts, or third-party runtime dependencies.

## Features

- Add projects from the open panel or by dragging them from Finder, then switch between them from a compact project sidebar.
- Browse matches by folder and file.
- Review each string with its source location and surrounding code.
- Approve one string or hold Option to approve the current file.
- Mark false positives as Not User-Facing.
- Automatically return changed text to the Review queue.
- Remember approvals and ignored matches without modifying the reviewed project.
- Uses an Xcode project’s app icon in the project sidebar when one is available.

## Supported projects

String Into Action scans:

| Project type | Files |
| --- | --- |
| Apple platforms | Swift, Objective-C, `.strings`, `.xcstrings`, storyboards, and XIBs |
| Web | JavaScript, JSX, TypeScript, TSX, HTML, Vue, and Svelte |
| Localization | Translation-oriented JSON files |

The scanner uses practical heuristics to favor useful review candidates. It skips common dependency/build folders, comments, logs and print statements, resource identifiers, image names, standard macOS main-menu strings, one-word literals, and other code-shaped values.

## Workflow

1. Open a project folder with File → Open Project, or just drag it into the sidebar.
2. Select a string in the Review queue.
3. Read it in context and edit it if needed.
4. Approve it, or mark it Not User-Facing.
5. Refresh after source changes. Newly discovered and changed text returns to Review.

Approved and ignored strings remain available from their respective filters. The All filter shows every discovered string.

## Keyboard shortcuts

| Action | Shortcut |
| --- | --- |
| Open a project | `⌘O` |
| Refresh strings | `⌘R` |
| Focus the string editor | `⌘E` |
| Approve | `Return` |
| Approve while editing | `⌘Return` |
| Approve all queued strings in the file | Hold `⌥` and choose Approve All in File |
| Approve all in the file with the keyboard | `⌥Return`, or `⌘⌥Return` while editing |
| Mark Not User-Facing | `⇧⌘I` |

## How review status is stored

Project history and sidebar preferences use `UserDefaults`. Review decisions are human-readable JSON files stored in:

```text
~/Library/Application Support/StringIntoAction/Reviews/
```

Each project gets a separate file named from a SHA-256 hash of its standardized path. Strings have persistent IDs, and approvals store a fingerprint of the exact literal content. After a scan, the app matches strings within the same file using their code structure, content, and, for duplicates, nearby code. Line numbers are used for identity only when the entire file is unchanged.

Inserting lines above a uniquely identifiable string or changing its indentation preserves its approval. A matched string whose text changes returns as Changed. Ignored strings also survive line shifts, but changed text returns to Review.

> [!IMPORTANT]
> Matching is conservative and heuristic. Indistinguishable duplicates, file renames, changes to surrounding code, or major refactors may require reviewing strings again.

Review files use a versioned schema and store matching fingerprints, not source text. On the first conversion from the older line-based format, the original JSON is preserved beside the review file with a `.v1-backup` extension. Only unique approvals whose exact text and location still match are migrated. Older ignored matches and other unmatched entries require review again because the old format lacks the context needed to match them safely. Old records remain in storage but do not apply to new IDs.

The reviewed project is never changed unless you explicitly save a supported text edit.

## Editing safety

Before writing, String Into Action verifies that the source file has not changed since it was scanned and that the original literal still occupies the expected range. Writes are atomic and preserve supported escaping and source encoding.

Complex Swift literals, interpolation, tagged JavaScript templates, unfamiliar escapes or HTML entities, and String Catalog keys can be reviewed but may be read-only. String Catalog scanning currently reviews source keys rather than translated values. UTF-8 source and BOM-marked UTF-16 `.strings` files are supported.

Symlinks are not followed. Files of 2 MB or larger and common dependency/build directories are skipped.

## Requirements

- macOS 14 or later
- Xcode 16 or later for development

## Build from source

Open `StringIntoAction.xcodeproj` in Xcode and run the `StringIntoAction` scheme, or build from Terminal:

```sh
xcodebuild \
  -project StringIntoAction.xcodeproj \
  -scheme StringIntoAction \
  -destination 'platform=macOS' \
  build
```

Run the complete test suite with:

```sh
xcodebuild \
  -project StringIntoAction.xcodeproj \
  -scheme StringIntoAction \
  -destination 'platform=macOS' \
  test
```

Core scanner, editor, persistence, and model tests can also run through Swift Package Manager:

```sh
swift test
```

## Contributing

Issues and human-generated pull requests are welcome. Please include regression coverage for scanner, persistence, or editing changes and run the test suite before opening a pull request.
