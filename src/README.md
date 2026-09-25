# BrewBar

A native SwiftUI menu-bar utility for Apple Silicon, macOS 13 Ventura or newer.

## Open, build, run

1. Open `BrewBar.xcodeproj` in Xcode 15 or newer.
2. Select the **BrewBar** scheme and **My Mac**, then press **Run** (⌘R).
3. Click the cup icon in the macOS menu bar. BrewBar intentionally has no Dock icon.

The project uses local ad-hoc signing and needs no dependencies or developer account for a local build. If Xcode requests signing details, select “Sign to Run Locally” under Signing & Capabilities. Developer ID signing and notarization are required for normal public distribution.

Without Xcode, installed Apple Command Line Tools can build it:

```sh
./build.sh
open build/BrewBar.app
```

The separately supplied `BrewBar-App.zip` contains an Apple Silicon build. It is ad-hoc signed, not notarized. Building locally in Xcode is the recommended route if macOS blocks the downloaded app.

## Using BrewBar

- **Update** fetches Homebrew and package definitions.
- **Outdated** lists available package updates.
- **Upgrade** installs available upgrades.
- **Cleanup** removes old versions and stale downloads according to Homebrew's normal policy; it does not indiscriminately empty the entire download cache.
- **Autoremove** uninstalls orphan dependencies.
- **Doctor** diagnoses configuration issues. Nonzero status can mean warnings that need attention; inspect the output.

Each action executes immediately. Read the descriptions before selecting Upgrade, Cleanup, or Autoremove: they change installed software or files. The command console displays merged stdout/stderr in arrival order, start/end timestamps, duration, and the actual exit code. Nonzero exits show “Needs attention.”

**Stop** signals the complete process group with SIGINT, then SIGTERM after three seconds, then SIGKILL after six seconds if still running. Completed changes cannot be undone by cancellation. Run Doctor afterwards if needed. A signal exit uses the conventional `128 + signal` code.

**Clear** clears the displayed buffer and pending text without stopping the command. **Copy** copies the currently retained output. The console retains a bounded recent tail (roughly 500 KB), trimming older output; logs are not written to disk. Turn off **Follow** to inspect earlier output while a command runs.

Only one operation runs at a time within the app. Closing the panel leaves the command running. Quit is blocked while an operation is active; stop it and wait before quitting. A process activity assertion reduces App Nap and prevents idle system sleep while a command runs; closing the lid or manually sleeping the Mac can still suspend work. Commands have no artificial execution time limit.

## Environment and limitations

BrewBar reads environment variables from `/bin/zsh -l` (including `.zprofile` and `.zlogin`, not interactive-only `.zshrc`). A five-second deadline cancels slow startup scripts and falls back to the inherited environment and standard paths. The UI remains responsive during discovery.

Resolution prefers `/opt/homebrew/bin/brew`, then the augmented login PATH, with `/usr/local/bin` and standard system paths as fallbacks. Commands launch directly using fixed arguments, without shell interpolation. The resolved path is displayed in the footer. Use the options menu to retry discovery after installing Homebrew.

This is a streaming, noninteractive output console rather than a full terminal emulator. stdin is `/dev/null`; colors are disabled and common ANSI color sequences are removed. Commands that require interactive input or administrator authentication cannot complete through this console. No passwords are collected or stored. Homebrew's normal auto-update behavior remains enabled.

App Sandbox is disabled because Homebrew needs access to its installation and package locations. The app does not coordinate with unrelated Terminal or other Homebrew apps; Homebrew's own locks still apply. Avoid running competing maintenance externally. No Homebrew maintenance was run while building or testing this project.

## Architecture

- `BrewBarApp.swift`: MenuBarExtra window, adaptive semantic colors, action grid, selectable scrolling console, accessibility labels, and quit protection.
- `BrewModel.swift`: main-thread observable state, environment discovery, throttled UTF-8 output, bounded retention, and process activity lifecycle. Owned at app level so closing the panel does not lose a running job.
- `CommandRunner.swift`: background POSIX process launcher with merged output pipe, dedicated process group, cancellation escalation, and exit-status decoding.

Uses system typography, SF Symbols, native controls, and semantic materials/colors to follow Light/Dark Mode automatically.

## Validation

Run `./test.sh`. It uses harmless shell fixtures to verify merged stdout/stderr, nonzero exit status, cancellation of a child process, launch failure, and environment/PATH defaults.

Verified in the delivery environment:
- Apple Swift 6.4 compiler, Swift 5 language mode, arm64 target, minimum macOS 13: optimized app build succeeded.
- Runner integration tests passed.
- Xcode project and Info.plist syntax validation passed.
- Ad-hoc code-signature verification passed.

Full Xcode build was unavailable because only Command Line Tools were installed. Automated visual inspection could not connect to the app (UI service timeout), so visual appearance and VoiceOver require manual verification.

Suggested manual checks: open in both Light and Dark appearance; navigate actions and controls with keyboard/VoiceOver; run Outdated/Doctor on a test Homebrew installation; check long-output scrolling with Follow disabled; close/reopen the panel during a command; cancel a long operation; verify all buttons remain disabled until exit; test missing Homebrew and retry.

Official references: [Apple MenuBarExtra window style](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window), [Homebrew command manual](https://docs.brew.sh/Manpage).

## Version 1.1 icons

Includes a custom amber terminal-cup app icon with all macOS icon sizes, a matching template menu-bar icon that follows system appearance, and branded dashboard artwork. Editable AppKit vector source is in `Design/RenderIcons.swift`. To regenerate, run `swift Design/RenderIcons.swift` from the project folder, then `iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`. Both the Xcode project and standalone build script bundle these resources.

## Version 1.2: Installed packages

Choose **Installed** in the same menu-bar window. BrewBar loads `brew info --json=v2 --installed` and shows installed Homebrew formulae and cask apps with name, description, installed version, and type. Search matches names, tokens, descriptions, and types. Software installed outside Homebrew is not included.

Select **Uninstall** on a row and confirm the named package. BrewBar runs `brew uninstall --formula <full_name>` or `brew uninstall --cask <full_token>` using separate, validated arguments. It does not add `--force`, `--ignore-dependencies`, or `--zap`. Homebrew's normal dependency checks remain active. Casks may run their own uninstall scripts; those requiring administrator interaction may fail in this noninteractive console.

The console below the list shows live uninstall output, cancellation, and exit status. All maintenance, inventory loading, and uninstall operations share the same busy guard. After a successful removal its row disappears; choose the refresh icon to verify the complete inventory, including any dependency changes. Failed/cancelled operations mark the inventory stale and retain rows until refresh. Refresh replaces the current console output; copy it first if needed.

JSON inventory output is isolated from stderr using a private temporary file, deleted after reading. Inventory failures display a retry message without discarding a previously loaded list. The installed list is held in memory only.

Version 1.2 validation: optimized Apple Silicon build passed; tests cover package parsing, formula/cask argument selection, option-like token rejection, malformed/empty JSON, and stdout/stderr separation, alongside the existing runner tests. A read-only `brew info --json=v2 --installed` check against the local Homebrew installation returned valid formula/cask data. No uninstall was performed. Xcode and interactive UI verification remain subject to the limitations above.

## Version 1.3: Available updates

The new **Updates** tab displays Homebrew's `outdated --json=v2` result as searchable rows, with installed → current versions and individual **Upgrade** buttons. Revision strings such as `0.12.0_1` are preserved exactly; BrewBar does not perform its own version comparisons. The Maintenance **Outdated** action now opens this list. Pinned entries, when reported by Homebrew, are labeled and disabled.

**Check** reads the current Homebrew definitions. **Refresh definitions** first runs `brew update`, then checks again. **Upgrade All** follows standard `brew upgrade` behavior. Self-updating/latest-version casks follow Homebrew's default selection rules and environment; BrewBar does not force `--greedy`. Different metadata freshness, Homebrew installations, or greedy settings in another app can produce different results. The resolved Homebrew path remains visible below the console.

Successful upgrade operations check updates again and append the check to the retained upgrade log. Failures/cancellations keep their exit status and mark results stale. Refresh errors preserve previous rows and show an error instead of reporting that everything is current. Operations share the existing concurrency guard and Stop control.

Validation: optimized Apple Silicon build and runner/parser tests passed. Regression fixtures cover the screenshot's jpeg-xl `0.12.0 → 0.12.0_1` and openexr `3.4.15_1 → 3.5.0`, cask routing, and empty/malformed data. A read-only check of the local Homebrew currently returned empty formulae/cask update arrays; the screenshot's entries could not be reproduced from that state. No package was upgraded during development. UI/Xcode verification limitations stated above still apply.

## Version 1.4: Appearance and supplied icons

A visible **System / Light / Dark** segmented selector appears below the header. The selection is saved across launches. System follows macOS; Light and Dark override the app's panels, controls, and console without changing macOS settings. The header switches between light/dark icon assets extracted from the supplied artwork. The running app icon also follows the displayed theme. The menu-bar glyph remains a macOS template image for legibility against the system menu bar.

The Finder bundle icon uses the light artwork; Finder does not follow this app's internal appearance preference. Both PNG variants are bundled in Resources. The old `Design/RenderIcons.swift` documents the previous vector design and should not be used to regenerate the new supplied artwork.

Version 1.4: optimized arm64 build and bundled-resource/signature validation passed. Interactive appearance and accessibility verification remain manual because the UI service previously timed out.

## Version 1.5: Console scrolling fix

The output console now scrolls vertically only and wraps long lines to its available width. Removed the horizontally unbounded text layout and minimum content width that caused Follow to move the viewport sideways. Re-enabling Follow jumps to the latest output. Copy still preserves the original output text; wrapping is visual only. Optimized arm64 build verified; interactive UI verification remains manual.

## Version 1.6: Terminal Mug menu-bar icon

Replaces the previous steaming cup with the selected Terminal Mug concept: a solid mug silhouette and transparent terminal chevron. Native 18-point template artwork includes 1x and 2x representations, automatically tinted by macOS. The icon stays consistent while commands run; progress remains visible in the panel. Editable vector source is in `Design/RenderMenuBar.swift`. Optimized arm64 build verified.

## Version 1.7: Uninstall confirmation fix

Replaced the modal uninstall alert with an inline confirmation card in Installed. Click Uninstall, then Confirm Uninstall or Cancel. This avoids a modal presentation/focus dependency in the menu-bar panel. Command execution clears any pending confirmation. Live output, Stop, dependency checks, and the single-operation guard remain active.

Regression tests use a temporary fake brew executable, never real package removal. Verified selection/cancel without execution, correct formula arguments, successful row removal, failed removal retaining its row and error output, blocked concurrent requests, and cancellation returning to an idle state. Optimized arm64 build passed. The reported modal freeze was not reproduced interactively; the modal path has been removed, and the underlying uninstall model/runner behavior passed these tests.

## Version 1.9: Version display and panel controls

The dashboard header now shows the app version beneath the tagline, e.g. `Version 1.9 (10)`. The string is read at runtime from the bundle's `Info.plist` (`CFBundleShortVersionString` and `CFBundleVersion`), so it always reflects the built bundle and requires no manual edit in code when the plist is bumped. A matching accessibility label is provided.

The header also adds visible **Close** and **Quit** buttons. Close dismisses the panel while BrewBar stays in the menu bar; Quit terminates the app and is disabled while a command is running (matching the existing quit-protection guard). The Quit button keeps the ⌘Q shortcut. Optimized arm64 build verified; the built bundle reports version 1.9 (build 10).

## Version 1.10: Live download progress

Long-running commands (Update, Upgrade, Cleanup, and per-package upgrades) now run under a pseudo-terminal (PTY) so Homebrew detects an interactive terminal and emits its live download progress bar. Previously brew ran on a plain pipe with `TERM=dumb`, which suppressed the progress bar entirely — a large bottle download would show a `Fetching…` line and then no visible movement until it finished.

`CommandRunner` gained a PTY path (`openpty` + `POSIX_SPAWN_SETSID`); the child's own session makes the slave its controlling terminal, and group-directed signals still reach it for Stop/cancel. JSON captures (installed/updates lists) stay on the plain pipe for clean, parseable output. The console model now honours carriage returns as in-place line rewrites, so the `####  100%` bar updates a single line instead of flooding the log — keeping both the live view and the Copy output clean. Downloads run sequentially (`HOMEBREW_DOWNLOAD_CONCURRENCY=1`) so brew prints the single-line progress bar rather than the newer multi-line animated parallel-download spinner, which a plain-text scrollback console cannot render. `TERM` is set to `xterm-256color` with colour disabled and stray escape codes stripped.

Optimized arm64 build verified; the built bundle reports version 1.10 (build 11).

## Version 1.11: MIT license

BrewBar is now released under the MIT License (a `LICENSE` file at the repository root; GitHub detects it as MIT). The panel footer shows a small `MIT License · © 2026 Ahmad Farid Abbas` line beneath the "One command at a time" status, and the website footer links the license.

Optimized arm64 build verified; the built bundle reports version 1.11 (build 12).

## Version 1.12: resilient update-data parsing

Fixed an intermittent "Could not read Homebrew update data" error that appeared even when `brew outdated --json=v2` exited 0. When Homebrew's API cache is cold it prints `==> Downloading Homebrew API data` to stdout before the JSON payload; that preamble landed in the same capture file and broke the strict JSON decode. Both the updates and installed-package parsers now trim the captured bytes to the outermost JSON object before decoding, tolerating any leading progress lines. Added regression tests covering the preamble case.

Optimized arm64 build verified; the built bundle reports version 1.12 (build 13).

## Version 1.13: Papery themes

The Appearance control expands from three options to five: **System**, **Light**, **Dark**, **Papery Light**, and **Papery Dark**. The two Papery themes are a warmer, stationery-inspired look — Papery Light is a cream/parchment base with dark ink text, Papery Dark is a charcoal-paper base with warm off-white text — both keeping BrewBar's amber accent (a slightly deeper amber on cream for contrast). A faint, static paper grain sits behind the panel content.

Under the hood this adds a real theming layer (`Theme.swift`): an `AppearanceMode` enum (migration-safe — unknown or legacy `"appearance"` values fall back to System) and a `Theme` value threaded through the SwiftUI environment. Views no longer hardcode system materials/colors; backgrounds, surfaces, borders, text, the console, and accents all resolve from the active theme. Papery modes ride on an underlying aqua/darkAqua `NSAppearance` so native controls stay legible, then override the visuals. The Appearance picker became a compact menu popup to fit five options in the 550-pt panel. Added `AppearanceMode`/`Theme` unit tests.

Optimized arm64 build verified; the built bundle reports version 1.13 (build 14).

## Version 1.14: Search & Install

The Installed tab gains a mode toggle — **Installed** and **Search & Install**. In Search mode, type a name and press Return to run `brew search`; BrewBar then enriches the candidates with `brew info --json=v2` so each result row shows a description, version, kind (formula/cask), and whether it's already installed. Installing runs through the same confirmation + live-console path as uninstall/upgrade (validated `install --formula`/`--cask <token>`, no shell interpolation). Already-installed results show an "Installed" marker instead of a button. On a successful install the results row flips to installed and the installed inventory auto-refreshes.

New `SearchResult` model + parser (reuses the v1.12 `JSONExtraction` preamble tolerance). Also fixed the warning/stale text color, which used the system `.orange` (`#FF9500`) and was hard to read on light backgrounds — it's now a darker burnt-orange (`#B35D00`) on light and a brighter amber-orange (`#FF9F3C`) on dark. Added search-parse and install-argument unit tests.

Optimized arm64 build verified; the built bundle reports version 1.14 (build 15).

## Version 1.15: Answer Homebrew's upgrade/install prompt

Homebrew 7 defaults `brew upgrade` and `brew install` to an "ask mode" that prints a summary and then waits for a `Do you want to proceed? [y/n]` confirmation. Because BrewBar runs brew under a pseudo-terminal (so it can show a live progress bar), brew saw a TTY, printed the prompt, and blocked forever — nothing ever answered it, so the command sat on "Running".

BrewBar now answers that prompt interactively. When brew asks, the console shows the question with **Yes** and **No** buttons (Return = Yes, Escape = No). The runner keeps the PTY master open and writes a single `y`/`n` character to it — matching brew's `$stdin.getch` read (no newline needed). Yes proceeds; No makes brew abort (`exit 1`), reported as "Needs attention". Stop still force-stops the process group.

Implementation: `CommandRunner` gained a `send(_:)` that writes to the PTY master (tracked as `inputFD`, cleared under lock when the fd closes). `BrewModel` detects the trailing `[y/n]`/`(y/N)` in the live output (`detectPrompt()`), exposes `awaitingInput`/`promptText`, and `answer(_:)` echoes the choice and forwards it to the runner. The prompt state clears on new command, completion, and Stop. JSON/file captures (search, info, outdated) never prompt because they don't use the PTY.

Optimized arm64 build verified; the built bundle reports version 1.15 (build 16).

## Version 1.15.1: Prompt-bar and Updates-list fixes

Two fixes to the v1.15 interactive prompt and the Updates tab:

- **Prompt bar lingered / could be answered repeatedly.** Detection scanned a large tail of the console for `[y/n]`, so after you answered, the still-present prompt text re-armed the bar and let you click Yes/No again (sending stray `y` characters). Detection is now *edge-triggered*: it arms only when the current **last line** is the prompt, and disarms the instant brew echoes the answer or prints its next line. `answer(_:)` disarms immediately, so a rapid second click is a no-op.
- **Other Upgrade buttons disabled after upgrading one package.** A successful upgrade set `updatesStale`, which disabled every remaining row's Upgrade button until a manual "Check". Now a successful single upgrade drops the upgraded row and re-checks in the background, so the remaining rows stay actionable; Upgrade All also re-checks. Failed/cancelled upgrades still mark the list stale.

Added an interactive-prompt regression test (arms once, answers via the PTY, does not re-arm; yes→exit 0, no→exit 1).

Optimized arm64 build verified; the built bundle reports version 1.15.1 (build 17).

## Version 1.16: Dedicated download progress bar

Downloads now show a **persistent progress bar** in the console instead of only brew's inline `#### NN.N%` text (which, for cask downloads like ChatGPT, often looked stalled after `==> Downloading …`). A dedicated bar sits below the console log while a file is fetching: it shows the file name, a linear `ProgressView`, and — when the size is known — `X MB of Y MB · NN%`. The bar stays visible for the whole download and disappears the moment it finishes, so the user always knows work is in progress rather than guessing whether to keep waiting.

Implementation: a new AppKit-free `DownloadProgress` model + `DownloadProgressParser` turns brew's PTY output into progress actions — `==> Downloading <url>` starts the bar (and extracts a readable file name, stripping query strings and percent-escapes), each `#### NN.N%` frame advances it, and `100%` / `Downloaded to:` / any following `==>` step ends it. Because brew's bar carries only a percentage, `BrewModel` issues a lightweight `HEAD` request on the download URL to learn the total size and derives the downloaded bytes from the live percentage (best-effort; the bar shows just the percentage if the size can't be fetched). The bar clears on command start/finish, Stop, and Clear, with a per-request token so a slow size lookup can't land on a later download. `BrewBarApp` renders the `DownloadProgressBar` view between the console scrollback and the toolbar. Added parser unit tests (start/advance/finish, file-name extraction, byte-summary formatting).

Optimized arm64 build verified; the built bundle reports version 1.16 (build 18).

## Version 1.17: Real byte progress from Homebrew's download queue

The download progress bar now shows Homebrew's own byte counter — e.g. `263.1 MB of 373.1 MB · 71%` — instead of a percent-plus-estimated size. v1.16 pinned `HOMEBREW_DOWNLOAD_CONCURRENCY=1` to get brew's single-line `#### NN.N%` bar (percentage only), and derived bytes from a `HEAD` request. This release enables brew's default parallel download queue, which prints a live status line with exact bytes: `⠋ Cask <name> (<ver>) ####  Downloading 263.1MB/373.1MB`.

That queue redraws each frame by moving the cursor to column 0 with a CHA control sequence (`ESC[0G`) rather than a bare carriage return, which is why a plain scrollback console previously couldn't render it (the frames piled up or vanished). The console model now translates `ESC[<n>G` to a carriage return before stripping the remaining ANSI (colours, cursor show/hide, synchronized-output `ESC[?2026h/l`, erase-line `ESC[K`), so each frame rewrites a single line in place — exactly like the old single-download bar. The progress parser gained a byte-counter branch (`Downloading X/Y` / `Downloaded X/Y`) that reads brew's real received/total figures (binary units) and the cask/formula name from the status line; these are authoritative, so no `HEAD` request is needed when they're present. The `HEAD`-estimate path remains as a fallback. The interactive `[y/n]` prompt handling is unchanged. Added byte-counter parser tests and verified against a real captured parallel-queue stream.

Optimized arm64 build verified; the built bundle reports version 1.17 (build 19).
