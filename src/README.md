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

## Version 1.29: Admin-password prompt for pkg casks (secure, never stored)

Some casks (e.g. Zoom) ship a `.pkg` payload whose install/uninstall runs `/usr/sbin/installer` or removes launchctl services under `sudo`. Homebrew asks for an administrator password via its `SUDO_ASKPASS` mechanism; because BrewBar previously ran brew with `SUDO_ASKPASS=/usr/bin/false` (to fail fast rather than hang on a hidden prompt), those operations dead-ended with `sudo: a password is required` and `Needs attention · Exit 1`. BrewBar now **securely collects the password and completes the operation**, while guaranteeing the password is never stored.

**Security model (the whole point).** The password is held in memory only for the duration of a single Homebrew command and is **never** placed in `argv`, in an environment variable, on disk, in the macOS Keychain, in `UserDefaults`, in the console log, or on the network. The path it takes: you type it into a masked `SecureField` (bound to `BrewModel.passwordDraft`); on Submit it is handed to a one-shot `AskpassBroker` and the on-screen draft is cleared; the broker writes it to a private FIFO (named pipe) — an in-kernel pipe buffer, *not* a file — inside a per-command temp directory (dir `0700`, FIFO `0600`, owned by the user). A tiny helper script set as `SUDO_ASKPASS` reads from that pipe and streams the password to `sudo`'s stdin (exactly the mechanism `sudo -A` expects; Homebrew only adds `-A` when `SUDO_ASKPASS` is set — `system_command.rb` L418). The draft is cleared on submit/cancel/dismiss, and the broker's in-memory copy + the temp FIFOs are destroyed the instant the command finishes, is stopped, or the console is cleared. For a multi-step action (e.g. a cask uninstall that removes several services), the broker caches the password for that one command so the user types it **once** and the remaining `sudo` prompts are answered from memory. Honest caveat: Swift strings aren't guaranteed-zeroed by the runtime, so a transient copy may briefly linger in freed memory until reused — the same practical limit every GUI `sudo` front-end has; BrewBar best-effort zeroes its own byte buffer after writing.

**Implementation.** New AppKit-free `Sources/BrewBar/AskpassBroker.swift` (so it compiles in both test targets): creates the temp dir + request/response FIFOs + helper script; `startWatching(onRequest:)` runs a background loop that opens the request FIFO (blocks until the helper signals), then either auto-answers from the cached password or raises the UI prompt; `sendPassword(_:)` / `declineOnce()` write to the response FIFO off the main queue (a separate concurrent queue from the watcher's serial queue — sharing one deadlocked `sendPassword` behind the watcher's blocking `open`, fixed during development); `cleanup()` is idempotent, unblocks both a parked watcher and a parked helper `cat`, and removes the dir. `BrewModel` gains `@Published awaitingPassword` + `passwordDraft`, a pure `commandMayNeedAdminPassword(_:)` classifier (cask `install`/`reinstall`/`uninstall`/`zap`, plus a bare `upgrade`), and wires `SUDO_ASKPASS=<broker helper>` for exactly those PTY commands (overriding the env's `/usr/bin/false`); `submitPassword`/`cancelPassword` forward to the broker and clear the draft; the broker is torn down on command start/finish/stop. `BrewBarApp` adds a `PasswordPromptBar` subview (lock icon + `SecureField` + Submit/Cancel) mirroring the `[y/n]` bar. (Toolchain note: `@State` is a SwiftUI macro unavailable under Command-Line-Tools `swiftc`, so the field binds to a model `@Published` instead — the app uses no `@State` anywhere.)

**Tests.** Five new regressions, all passing: a pure helper-script/escaping check and two end-to-end broker handshakes in RunnerTests (deliver the password to the helper's stdout; decline → empty password); the `commandMayNeedAdminPassword` classifier, a full model→broker→helper install (a fake brew reads `SUDO_ASKPASS`, runs the helper, captures the password, exits 0 only if it matches), the cancel path, and a repeated-prompt caching test (two `sudo` prompts answered after one entry) in UninstallTests. `AskpassBroker.swift` added to both `test.sh` swiftc lines.

Optimized arm64 build verified; the built bundle reports version 1.29 (build 38). All 32 test suites pass.

## Version 1.30: Completed download bars always render green

Fixes a color inconsistency in the console's live multi-download block. When a download finished **while the panel was open**, its progress bar turned green (correct); but if a download was *already complete* when the panel first rendered — for example after closing and reopening the app during a `brew upgrade` — that same bar rendered in the macOS system accent (blue) instead of green. So a single block could show a mix of green and blue "done" bars.

**Root cause.** The rows used a SwiftUI `ProgressView(value:)` tinted with `.tint(entry.done ? .green : accent)`. A `ProgressView` that is *born full* (created already at `fraction == 1.0`) does not reliably pick up a `.tint` applied in the same render pass and falls back to the system accent color (blue). A bar that animates up to completion while live has its tint resolved before it fills, so it shows green — hence the live-vs-reopen discrepancy. The `downloads` array is in-memory only (not persisted), so this was purely a first-paint rendering quirk, not a state problem.

**Fix.** Replaced the system `ProgressView` in `LiveDownloads` (`BrewBarApp.swift`) with an explicit capsule bar: a faint track plus a filled `Capsule` whose width is `geometry.width × fraction`, drawn directly in `entry.done ? .green : theme.accent`. Because the fill color is painted explicitly rather than via `.tint`, a completed bar is always green regardless of whether it finished live or was already complete at first paint. View-only change; all existing tests continue to pass.

Optimized arm64 build verified; the built bundle reports version 1.30 (build 39). All 32 test suites pass.

## Version 2.0: Info button runs a visible `brew info` in the console

Clicking the ⓘ info button on a Search & Install (or Installed / Updates) row now runs a **visible, human-readable `brew info <token>`** into BrewBar's console — the same formatted detail you'd see in Terminal (description, homepage, install state, Caskroom path/size, requirements, artifacts, and analytics) — in addition to the structured popover.

**Behavior.** Previously the ⓘ button ran only a quiet `brew info --json=v2 <token>` captured to a temp file (so the console stayed silent) and parsed the JSON into the popover. Now the click first runs a plain `brew info <--cask|--formula> <token>` that streams the Terminal-style text into the console, then **chains** the quiet JSON capture (`preserveOutput: true`, so the plain text stays visible) to fill the popover's structured fields. You get both: the rich inline detail in the console *and* the compact popover with the "Open homepage" link.

**Implementation.** `BrewModel.fetchInfo(token:kind:id:)` now runs the visible plain command and, in its completion, calls a new private `loadInfoDetail(token:flag:id:)` that performs the JSON capture + `PackageInfo.parse`. Chaining is safe because `execute` sets `busy = false` before invoking the completion (the same invariant the search→info chain relies on). The token is still validated against a strict `^[A-Za-z0-9][A-Za-z0-9@+._/-]*$` pattern and passed as a fixed argument (no shell interpolation), and the popover's cancel/dismiss/invalid-token guards are preserved. If the user closes or switches the popover between the two commands, the JSON fetch is skipped.

**Tests.** The existing `fetchInfo` regression (UninstallTests) was extended to assert the visible plain `brew info --formula wget` command appears in the console output *and* that `packageInfo` is still populated from the chained JSON capture; all other guards (arms target + loading immediately, dismiss clears state, invalid token rejected) unchanged.

Optimized arm64 build verified; the built bundle reports version 2.0 (build 40). All test suites pass.

## Version 2.0.1: `brew info` metadata fetch no longer pops the download bar

A follow-up to 2.0. Clicking ⓘ runs a visible `brew info <token>`, and that command fetches Homebrew's cask/formula definition from the API (e.g. `==> Downloading https://formulae.brew.sh/api/cask/alt-tab.json`). BrewBar's live-download detector saw that `==> Downloading <url>` line and briefly popped the "Downloading 1 item" progress block for the tiny JSON definition file — noise for what is only a read-only info lookup.

**Fix.** `DownloadProgressParser.parse` now ignores a `==> Downloading` line whose URL is brew's API metadata — a new `isAPIMetadataURL` helper matches host `formulae.brew.sh` with an `/api/…` path ending in `.json` and returns `.none`, in the same spirit as the existing `Downloading Homebrew API data` filter. The match is narrow (host + `/api/…json`) so a real package artifact that merely happens to be a `.json` on another host still starts a normal download.

**Tests.** RunnerTests gained assertions that the cask and formula API metadata URLs (`/api/cask/alt-tab.json`, `/api/formula/wget.json`) return `.none`, that `isAPIMetadataURL` is true for those and false for a non-API `.json` artifact, and that a non-API `.json` URL still starts a download.

Optimized arm64 build verified; the built bundle reports version 2.0.1 (build 41). All test suites pass.

## Version 2.1: Clear (✕) button on search fields

Every search field in the app now has a **✕ clear button** that appears only when the field has text and wipes it in one click. Added to all three text inputs: **Search & Install** (clears the query *and* resets the results back to the empty prompt, dismissing any pending install confirmation), the **Installed** filter (clears the filter so the full inventory shows again), and the **Updates** search filter. The ✕ sits inline at the trailing edge of each field, styled with the app's secondary text color and a standard `xmark.circle.fill` glyph, with a "Clear search" accessibility label and tooltip. The password `SecureField` is intentionally left untouched (it already has Submit/Cancel, and a clear control there would be unusual).

**Implementation.** A new `BrewModel.clearSearch()` resets `searchQuery`, `searchResults`, `searchError`, `searchPerformed`, and `installCandidate` for the Search & Install field; the two filter fields clear their bound string directly (`model.search = ""` / `model.updateSearch = ""`), which restores the unfiltered list. Each ✕ is wrapped in an `if !field.isEmpty` so it only shows when there's text to clear.

**Tests.** The install-flow regression (UninstallTests) now seeds a query + results + error + candidate, calls `clearSearch()`, and asserts every field is reset to empty before continuing with the install assertions.

Optimized arm64 build verified; the built bundle reports version 2.1 (build 42). All test suites pass.

## Version 1.28.5: Multi-download console no longer garbles (flush chunk-boundary fix)

Fixes the long-standing multi-item download garble that resurfaced on real `brew upgrade` with two concurrent casks (e.g. firefox + google-chrome): the live download block drifted and left a trail of stale rows, byte counters broke onto their own lines, and `· name — X MB / Y MB` snapshot lines leaked into the scrollback mid-download.

**Root cause.** `BrewModel.flush` runs on a 0.1s timer and trimmed incomplete *UTF-8* at chunk boundaries but not incomplete *ANSI escape sequences* or partial lines. Homebrew's parallel download queue redraws its block every ~0.05s with CSI cursor-motion/erase codes (`ESC[1F`, `ESC[K`, `ESC[?2026h/l`). When a flush slice ended in the middle of one of those sequences, two things broke: (1) the terminal emulator's `consumeEscape` ran off the end of the buffer and silently dropped the sequence, so a frame's cursor-up or erase was lost and the block drifted downward; (2) the structured parser (`detectDownload`) received partial lines, which spuriously matched a finish pattern and fired `commitDownloads()` mid-download, folding a snapshot into the scrollback. The emulator logic itself was correct — a whole-stream replay rendered cleanly; only the chunk-splitting was at fault.

**Fix.** `flush` now holds back a trailing incomplete escape sequence (a static `escapeSafeCount` scans for an unterminated `ESC`/CSI/OSC and defers it to the next slice, exactly as the UTF-8 trim already did), and buffers a trailing partial line (`cleanRemainder`) so the parser only ever sees complete lines. Both deferrals are flushed on the final read. Verified against a real captured firefox+chrome queue stream (replayed whole = clean; replayed in escape-splitting slices = clean with the fix, garbled without). Regression tests: a pure `escapeSafeCount` unit suite (lone ESC, partial CSI, partial DEC-private, complete sequence, no-escape) and a deterministic slicing simulation that replays the queue stream through the exact flush slicing + emulator and asserts one firefox + one chrome row (bypassing the guard reproduces the drift + garbled escape fragments).

Optimized arm64 build verified; the built bundle reports version 1.28.5 (build 37). All 27 test suites pass.

## Version 1.28.4: About-check console block no longer cascades; tighter line spacing

A follow-up to 1.28.3. The manual update-check prints an About block to the console — `[time] Checking for BrewBar updates…`, then `Current version:` / `Bundle ID:` / `Location:` / `macOS:` / the result line. 1.28.3 aligned the labels *within* the block, but the block as a whole still began at the stale cursor column left by the previous command's output, and because every internal line feed preserves the column (correct per the 1.28 terminal model), each line cascaded progressively further to the right.

**Fix.** Every line emitted by `logAppUpdateHeader` (the first line and each padded row) and by `logAppUpdate` (the result line) is now prefixed with a carriage return (`\r…`), resetting the column to 0 before the text is written — so the whole block starts at the left margin regardless of where the previous command left the cursor. Added a regression test driving `checkForAppUpdate(manual:)` after a finished command and asserting the header line, each labelled row, and the macOS row all start at column 0; reverting the header `\r` reproduces the exact cascade symptom.

**Also:** reduced the console's text `lineSpacing` from 4 to 2 for a tighter, less loosely-spaced log, as requested.

Optimized arm64 build verified; the built bundle reports version 1.28.4 (build 36). All 25 test suites pass.

## Version 1.28.3: Non-PTY console lines and About-info columns no longer indented

A follow-up to the 1.28.x terminal-fidelity line, fixing two remaining alignment bugs reported from console screenshots.

**Bug 1 — brew's non-PTY preamble stair-stepped to the right.** The JSON commands (`brew outdated --json=v2`, `brew info`, `brew search`) run on a plain pipe, not a PTY. On that path brew prints progressive plain lines with no carriage returns — e.g. its auto-update preamble `==> Auto-updating Homebrew...` / `==> Auto-updated Homebrew!` / `==> Updated Homebrew from …`. Because the 1.28 terminal fix makes a bare line feed correctly *preserve* the column (as a real terminal does for the PTY download queue), each of these plain lines inherited the previous line's stale column and marched to the right.

**Fix.** The model now tracks whether a command runs under a PTY (`usingPTY`). For the non-PTY path, `flush` normalises every bare line feed to `\r\n` (via a pure `normalizeLineBreaks` helper) before feeding the terminal emulator, so each line resets to column 0 — matching how a dumb pipe consumer prints brew's output. The PTY path (download queue, with real in-place cursor redraws) is untouched, so that fidelity is preserved. Added three regression tests: the pure helper transform, an emulator-level reproduction (raw bare-LF stair-steps; CRLF fixes it), and an end-to-end `checkUpdates` test driving a fake brew that writes an `==>` preamble to stderr — reverting the fix reproduces the exact right-indent symptom.

**Bug 2 — About-info columns misaligned.** The manual update-check header (`Current version:` / `Bundle ID:` / `Location:` / `macOS:`) aligned its values with hand-typed spaces, which left `Current version:` one column off from the other three. Replaced the literal padding with programmatic label padding (each label padded to a fixed width), so every value starts at the same column and the alignment can't drift when labels change.

Optimized arm64 build verified; the built bundle reports version 1.28.3 (build 35). All 24 test suites pass.

## Version 1.28.2: Console summary lines no longer indented

A follow-up to 1.28.1. The status footer line was fixed in 1.28.1, but the app's own result-summary lines that are appended *after* it still inherited the stale cursor column, so they rendered indented far to the right. Visible as "Loaded N installed Homebrew packages." (Installed), "N available updates in current definitions." (Updates), "Found N installable packages for …" (Search), and — when a chained command re-ran with the previous log preserved — a duplicate command heading pushed to the right.

**Cause.** Same class as 1.28.1. The completion status line ends with a bare line feed, which (correctly, per the 1.28 terminal fix) preserves the column — leaving the emulator cursor parked at that line's stale column. Every synthetic summary line appended afterward, and the `preserveOutput` chained-command heading (appended as `"\n" + heading`), began at that stale column instead of column 0.

**Fix.** Each synthetic summary append now starts with a carriage return (`\r…`), and the `preserveOutput` heading separator is now `\r\n` instead of `\n`, resetting the column to 0 so every line starts at the left margin. Added a regression test (the `checkUpdates` path) asserting the "N available updates" summary line begins at column 0; reverting the fix reproduces the exact right-indent symptom.

Optimized arm64 build verified; the built bundle reports version 1.28.2 (build 34). All 22 test suites pass.

## Version 1.28.1: Console status line no longer indented

A follow-up to 1.28. After a command finished, the synthetic status footer line (e.g. `[2:28 AM] Succeeded · Exit 0`) could appear indented far to the right instead of starting at the left margin — most visible after `brew outdated` when nothing is outdated.

**Cause.** On completion, `BrewModel` trims trailing newlines from the console text and re-seeds the terminal emulator; `seed` leaves the cursor at the END of brew's last output line. The status line was then appended with a leading bare line feed (`\n`), and — correctly, per the terminal fix in 1.28 — a line feed preserves the column, so the status line started at brew's stale cursor column rather than at column 0.

**Fix.** The status line (and the cancelled-rollback note) is now prefixed with a carriage return before the line feed (`\r\n` / `\r`), resetting the column to 0 so it always starts at the left margin regardless of where brew left the cursor. Added a regression test driving a fake brew whose output has no trailing newline and asserting the status line begins at column 0.

Optimized arm64 build verified; the built bundle reports version 1.28.1 (build 33). All 21 test suites pass.

## Version 1.28: Faithful multi-download console (CRLF terminal fix)

Fixes a console-rendering bug where real `brew` output — especially the parallel download queue and the `✔︎ Cask … (version)` completion lines — rendered with each line marching progressively to the right, so a multi-cask fetch looked garbled instead of matching Terminal.app.

**Root cause.** BrewBar's `TerminalEmulator` iterated the output stream by Swift `Character` (extended grapheme clusters). Homebrew terminates each status line with a carriage-return + line-feed (`"\r\n"`), and Swift treats `"\r\n"` as a **single** `Character` (scalars `[13, 10]`). The emulator's loop saw that one combined grapheme, matched neither the bare-`\r` nor the bare-`\n` case, and handled it as a plain line feed — so the carriage return's **column reset was lost**, and every subsequent line was padded with the previous line's width.

**Fix.** The emulator now iterates **Unicode scalars**, so `\r` (column 0) and `\n` (next row) are always distinct control codes, exactly as a real terminal processes a byte stream. Zero-width combining marks and variation selectors (e.g. the `U+FE0E` after brew's `✔` check mark) are folded onto the previous cell, so `✔︎` renders as one glyph without disturbing column math. Escape-sequence parsing (`consumeEscape`/`applyCSI`) was converted to scalars to match. Verified against two real captured `brew fetch --cask` streams (`alt-tab clipy cotypist` and `google-chrome firefox`): both render clean, with SGR colour codes stripped and no padding. A CRLF + SGR-check-mark regression test was added to `RunnerTests`, and the `UninstallTests` compile line in `test.sh` now includes `TerminalEmulator.swift` (which `BrewModel` depends on) — all 20 test suites pass.

Optimized arm64 build verified; the built bundle reports version 1.28 (build 32).

## Version 1.27.1: Segmented-tab focus-ring fix

Fixes a visual glitch where the selected tab in the **Maintenance / Installed / Updates** segmented control (and the **Installed / Search & Install** mode toggle) drew a stray blue macOS keyboard focus ring around the active segment. SwiftUI's `.focusable(false)` doesn't reliably suppress the ring that AppKit paints on the underlying `NSSegmentedControl`, so a small `NSViewRepresentable` (`SegmentedFocusRingSuppressor`, applied via a `.hideSegmentedFocusRing()` view modifier) now reaches the backing control and sets `focusRingType = .none`. Rendered as a zero-size background, so layout is unaffected. Build 31; all 19 test suites pass.

## Version 1.27: One-click self-update

BrewBar can now update itself. When a newer release is available, **Options → Update to X** (or the **Update to X** pill in the header) downloads the new build, verifies it, replaces the app in place, and relaunches — no browser, no drag-and-drop.

**How it works.** The resolved release ZIP is downloaded (progress shown on the pill/menu), its SHA-256 is checked against the published `SHA256SUMS.txt` (a mismatch aborts and leaves the app untouched; if the sums can't be fetched it proceeds, since the download comes from the signed release), it's expanded with `ditto`, the quarantine flag is cleared, and a small detached helper waits for BrewBar to quit, swaps the bundle, and relaunches the new version. The swap is fail-safe: the old app is moved aside first and rolled back if the move-in fails, so a permission error or interruption never leaves a half-installed app. No Apple Developer account is required — the updater clears quarantine and the app stays ad-hoc signed.

"View Release Notes…" remains available in the Options menu for anyone who prefers the manual download.

Optimized arm64 build verified; the built bundle reports version 1.27 (build 30). All 19 test suites pass, including new coverage for release-asset URL extraction, `SHA256SUMS.txt` parsing, and the asset filename/fallback-URL helpers.

## Version 1.26.1: Build details in the console on update check

A small follow-up to 1.26. When you choose **Options → Check for Updates…**, BrewBar now prints the running build's details to the console before reporting the result — a visible record of exactly what's installed:

```
[time] Checking for BrewBar updates…
  Current version: 1.26.1 (build 29)
  Bundle ID:       com.brewbar.app
  Location:        /Applications/BrewBar.app
  macOS:           Version 14.x …
  You're up to date — BrewBar 1.26.1 is the latest release.
```

The result line reflects the outcome (up to date / an available version with its tag / a connection error). Logging is skipped while a Homebrew command is running so it never interleaves with live command output (the menu still shows the status either way).

Optimized arm64 build verified; the built bundle reports version 1.26.1 (build 29). All 19 test suites pass.

## Version 1.26: In-app update check + Quit cleanup

**Check for Updates (Phase 1).** BrewBar now notices when a newer version has been released. A lightweight background check (shortly after launch, then every 6 hours) queries the GitHub Releases API for the latest tag and compares it to the running version. When a newer release exists it's surfaced in two places: an **Options → Check for Updates…** item (which becomes **Download Update — X…**), and a small tappable **"Update available — X"** pill under the version text in the header. Clicking either opens the GitHub release page to download the new build. This is the detect-and-guide phase — it does not replace the app in place (a one-click self-update is a planned follow-up). The check is fail-safe (any network/parse error simply leaves the state as "no update", never a false nag) and never blocks the UI. The version comparison is a pure, unit-tested helper (`AppUpdate.isNewer`) that tolerates `v`-prefixed tags and pre-release suffixes.

**Removed the duplicate Quit.** The Options menu previously had a second "Quit BrewBar" item in addition to the header Quit button, which also meant `⌘Q` was bound twice — and the menu item wasn't guarded against quitting mid-command like the header button is. The menu item is gone; the single busy-guarded Quit button in the header remains (and `AppDelegate.applicationShouldTerminate` still warns if you try to quit while Homebrew is running).

Optimized arm64 build verified; the built bundle reports version 1.26 (build 28). All 19 test suites pass, including new coverage for the update version-compare, tag parsing, and fail-safe guards.

## Version 1.25: Parallel-download console block

Fixes the garbled console text and mismatched progress bar seen when Homebrew downloads multiple casks at once (its default parallel download queue).

**The problem.** With several downloads running concurrently, brew redraws a multi-line status block each frame. The console only translated the horizontal cursor move (`ESC[0G` → carriage return) and stripped the vertical moves, so each repaint was appended rather than overwriting — producing stacked, interleaved lines like `Cask homebrew-app … Downloading 2.9MB/5.2MB⣿ Bottle gh … Downloading`. Separately, the progress bar was a single slot, so with multiple downloads it showed one package's name paired with another's byte counts (e.g. "chatgpt · 2.9 MB of 5.2 MB" when chatgpt is 682 MB).

**The fix — structured, keyed download tracking.** Instead of emulating a terminal, BrewBar now parses each parallel-queue line into a keyed `DownloadEntry` (name → received/total bytes) and rebuilds the block from its own state. `BrewModel.downloads` is an insertion-ordered collection; `detectDownload` upserts entries by package name, so every row always pairs the right name with the right bytes — no stacking, no mismatch. A completed entry is marked done (kept at 100%) and the whole block stays until **every** download finishes, then commits a text snapshot into the log and clears so the install phase continues normally.

**The UI — pinned live block.** The old single `DownloadProgressBar` is replaced by `LiveDownloads`, rendered *outside* the scrolling console (between it and the toolbar). It shows a header (`Downloading N items` · `x/N done`) and one row per package: a green check when done, the name, an inline mini progress bar (green at 100%), and brew's byte counter. Because it's pinned outside the scroll area, download progress stays visible regardless of the Follow toggle, and it scales to any concurrency. The HEAD size-lookup request was removed (brew's own byte counts are authoritative). Copy now includes a snapshot of the live block.

Optimized arm64 build verified; the built bundle reports version 1.25 (build 27). All 18 test suites pass, including the extended download-progress parser tests (named completion stays a `.bytes(complete:)` marker so the block can hold a finished row at 100%).

## Version 1.24: Console performance & scroll-blanking fix

Two fixes to the live command console, which could go blank while scrolling and made the menu-bar UI feel stuck during downloads.

**Console no longer blanks on scroll.** The console was a single large, selectable SwiftUI `Text` inside a `ScrollView`. That combination intermittently rendered blank mid-scroll (the content height was correct — the scrollbar showed — but no glyphs drew), and it re-laid-out the entire log string on every `output` mutation. The console is now an `NSTextView` inside an `NSScrollView` (`ConsoleOutput: NSViewRepresentable`), which handles large, incrementally-appended, selectable monospaced logs without blanking and only re-lays-out the delta. Auto-scroll (Follow) is done with AppKit's `scrollToEndOfDocument` and only fires when the text actually changes.

**Menu bar no longer lags during downloads.** With Homebrew's parallel download queue redrawing a byte-counter status line many times per second, the old per-character `append` loop did an O(n) `removeSubrange` on the whole `output` string on every carriage return, plus a SwiftUI `scrollTo` animation ~10×/second — starving the main actor so the `MenuBarExtra` felt stuck. `append` now processes incoming text in bulk segments split on `\r` (at most one line-truncation per carriage return), and the per-mutation SwiftUI scroll animation is gone (AppKit handles it). Combined with the `NSTextView` console, this keeps the main thread responsive while big casks download.

Optimized arm64 build verified; the built bundle reports version 1.24 (build 26).

## Version 1.23: Brewfile export fixes

Two fixes to the v1.22 Brewfile feature.

**Export no longer passes the disabled `--describe` switch.** `brew bundle dump --force --describe` failed on current Homebrew (7.x) with `Error: Calling the '--describe' switch is disabled! Use the default behaviour instead.` — the switch was removed and description comments are now the default. Export now runs `brew bundle dump --force --file=<path>` (descriptions still included). Added a test that pins the exact dump arguments and asserts `--describe` is never passed.

**Save/Open panels now open in front.** The Export save panel and Restore open panel could appear *behind* the BrewBar window. A `MenuBarExtra(.window)` app (LSUIElement) isn't "active" like a normal app, so a freshly created `NSSavePanel`/`NSOpenPanel` wasn't brought forward. Both panels now call `NSApplication.shared.activate(ignoringOtherApps:)` and raise the panel to `.modalPanel` level immediately before `runModal()`, so they appear on top.

Optimized arm64 build verified; the built bundle reports version 1.23 (build 25).

## Version 1.22: Update badge, package info popover, and Brewfile backup/restore

Three features in one release.

**Menu-bar update badge.** BrewBar now checks for outdated packages in the background — once about 8 seconds after launch, then every 6 hours — and shows the count in the menu-bar label ("BrewBar — 3 updates") plus a small amber dot composited onto the Terminal-Mug glyph. The background check runs on its own `CommandRunner` (never through `execute`), so it never writes to the console, never toggles `busy`, and is skipped entirely while a foreground command is running — it can't collide with anything you do. `updateCount` is also set by the normal manual Check. Implemented as `BrewModel.backgroundCheckUpdates()` + `startBackgroundUpdateChecks()` (a launch delay + a repeating `Timer`, each hop wrapped in `Task { @MainActor }`), and `BrandImages.menuBarBadged(count:running:)` which returns the plain template glyph when there's nothing pending (so the OS still tints it) or a non-template composite with the amber dot when updates exist.

**Per-package info popover.** Every package row (Installed, Search & Install, and Updates) gained an ⓘ button that opens a popover with the description, version, dependencies, install size (formulae), caveats, and a homepage link that opens in the default browser. A new pure, AppKit-free `PackageInfo` model + `PackageInfo.parse` decodes `brew info --json=v2 <token>` (formula `dependencies` + `installed[].installed_size`; cask `depends_on.formula`/`.cask`; `caveats`; a `homepageIsValid` guard that only allows http(s) URLs to be opened). `BrewModel.fetchInfo(token:kind:id:)` captures the JSON quietly to a temp file (like `refreshInstalled`, so the console isn't spammed), gated by the one-command `!busy` invariant, and drops the result if the user closed the popover meanwhile. `PackageInfoPopover` renders the loading/error/detail states.

**Brewfile backup & restore.** The Maintenance tab gained a Brewfile row: **Export** shows a save panel and runs `brew bundle dump --force --describe --file=<path>`; **Restore** shows an open panel, then a confirmation bar in the console (mirroring the install/uninstall confirm pattern) before running `brew bundle install --file=<path>`. The chosen path is passed as a single argv element (no shell interpolation). A successful restore marks the installed inventory and updates as stale.

Tests: `PackageInfo` parsing (formula deps/size/caveats, cask `depends_on`, homepage guard, byte formatting, preamble tolerance) in RunnerTests; model-level flow tests in UninstallTests for `fetchInfo` (arms target + loading, populates `packageInfo`, dismiss + invalid-token guards), Brewfile restore (`bundle install` with the chosen file, cancel/no-candidate no-ops), and `updateCount` reflecting the latest outdated check. `PackageInfo.swift` added to both `test.sh` swiftc lines.

Optimized arm64 build verified; the built bundle reports version 1.22 (build 24).

## Version 1.21: Prevent the leftover-app cask failure at the source

v1.20 added a one-click recovery for the `It seems there is already an App at '…'` cask-upgrade failure. This release prevents it from happening in the first place for the common case. The failure only occurs on a **targeted** single-package upgrade (`brew upgrade --cask <name>`, which the Updates tab's per-package Upgrade button runs); Homebrew's auto-upgrade path (a bare `brew upgrade`, which Upgrade All and a Terminal `brew upgrade` use) already replaces such casks cleanly. Self-updating apps (WhatsApp, Chrome, …) overwrite their own `.app` and drift out of sync with the Caskroom, so the targeted upgrade trips on the leftover artifact while the bare upgrade does not.

Implementation: `PackageUpdate.arguments` now appends `--force` for casks only — `["upgrade", "--cask", "--force", name]` — so a per-package cask upgrade behaves like brew's auto-upgrade and overwrites the stale app instead of dead-ending. Formulae never carry a `.app` artifact and are unchanged (`["upgrade", "--formula", name]`, no `--force`). The v1.20 Force Retry recovery bar stays as a safety net for any residual case. Updated the arguments test to expect `--force` on casks and to assert formulae do **not** force.

Optimized arm64 build verified; the built bundle reports version 1.21 (build 23).

## Version 1.20: Recover from a leftover-app cask upgrade failure

Some cask upgrades (e.g. `brew upgrade --cask whatsapp`) can fail with `Error: <token>: It seems there is already an App at '…'.` — an older `.app` from the previous version is still in place and blocks the install, so brew stops with a non-zero exit. Previously the only fix was to drop to a Terminal and re-run with `--force` by hand. BrewBar now detects this failure and offers a one-click recovery, reusing the recovery-bar infrastructure introduced in v1.19.

Implementation: the pure, AppKit-free `RecoveryHint` model gained a `Kind` enum (`.resumableDownload`, `.staleAppArtifact`) that drives the message, primary-button title/symbol, and recovery action. `RecoveryHintDetector` now scans for the distinctive `It seems there is already an App at` phrase and extracts the affected token from the `Error: <token>:` prefix (always a cask, since only casks carry the `.app` artifact); the resumable-download detection is unchanged and still takes its own path. On a matching non-cancelled failure, `BrewModel` publishes the hint and the console recovery bar shows **Force Retry** + **Dismiss**. `performRecovery()` (the generalized successor to `retryAfterCacheClear()`) dispatches on the hint's kind: clear-cache-then-rerun for downloads, or re-run the exact failed command with `--force` appended (fixed args, no shell interpolation) for the stale artifact — output preserved so the whole recovery story stays in one console log, with updates re-checked on success. Added stale-artifact detection tests (token/cask flag, force-retry action, false-positive guard) and a full flow test (fake brew fails `upgrade` with the "already an App" signature → recovery set kind `.staleAppArtifact` token `whatsapp` → `performRecovery()` re-runs with `--force` to exit 0 → recovery cleared).

Optimized arm64 build verified; the built bundle reports version 1.20 (build 22).

## Version 1.19: Recover from Homebrew's "cannot resume" download dead-end

Some cask upgrades (e.g. `brew upgrade --cask postman`) can fail with `curl: (56) HTTP server doesn't seem to support byte ranges. Cannot resume.` — a stale partial download sits in Homebrew's cache and the CDN refuses a Range request, so brew keeps trying to resume and hits a dead-end. Previously the only fix was to drop to a Terminal and run `brew cleanup <package>` by hand. BrewBar now detects this failure and offers a one-click recovery.

Implementation: a new pure, AppKit-free `RecoveryHint` model + `RecoveryHintDetector` scans a failed command's output for the signature — a `curl: (56)` line together with a resume phrase, or an explicit "cannot resume" / "byte ranges" phrase — and extracts the offending package token and kind (cask/formula) from brew's `Download failed on Cask 'postman'` / `Formula 'wget'` line. The detector requires the resume signature specifically, so unrelated curl-56 errors (connection reset, etc.) are **not** offered a cache-clear (a false-positive guard). On a real (non-cancelled) failure whose output matches, `BrewModel` publishes a `recovery` hint; `BrewBarApp` shows a warning-tinted recovery bar in the console (mirroring the `[y/n]` prompt bar) with **Clear Cache & Retry** and **Dismiss**. Retry runs `brew cleanup <token>` (fixed args, no shell interpolation; falls back to a global `brew cleanup` when brew didn't name a package), then re-runs the exact failed command with output preserved so the whole recovery story stays in one console log, and re-checks updates on success. The offer clears on a new command, Stop, or Clear. Added recovery-hint detection tests (curl-56 resume, formula/cask token extraction, byte-ranges-only phrasing, tokenless hint, false-positive guards) and a full flow test (fake resume-failing `brew upgrade` → recovery set → cache-clear + re-run to exit 0 → recovery cleared).

Optimized arm64 build verified; the built bundle reports version 1.19 (build 21).

## Version 1.18: Reliable multi-word Search & Install

Searching **Search & Install** with more than one word (e.g. `tinycast Beta`) previously returned the wrong package or nothing at all. Homebrew's `brew search` matches a query against package **tokens** — which are always lowercase and never contain spaces (`tinycast@beta`, `google-chrome`) — so a human, multi-word query can't substring-match any real token; brew falls back to a fuzzy match and surfaces an unrelated result (a search for "Tinycast Beta" returned only `tinymist`). This release makes multi-word search reliable.

Implementation: a two-stage strategy in the pure, testable `SearchResult` helpers. `distinctiveTerm(_:)` reduces the query to the single most distinctive (longest) brew-safe word — `tinycast Beta` → `tinycast` — and that single term is what's handed to `brew search`, which reliably returns every `tinycast*` candidate. Then `matches(query:)` filters the enriched results client-side, keeping only packages whose **token or display name** contains every word of the original query — so `tinycast Beta` resolves to exactly `tinycast@beta` ("Tinycast Beta"), and `tinymist` is dropped. Single-word queries pass through unchanged (no regression), and a defensive fallback shows all candidates if the client filter would otherwise empty a non-empty result set. Added parser unit tests for `distinctiveTerm` (longest-word selection, single-word passthrough, blank input, tie resolves to first) and `matches` (multi-word survival/exclusion, single-word substring), including the full tinycast set resolving to exactly the Beta package.

Optimized arm64 build verified; the built bundle reports version 1.18 (build 20).

## Version 1.17: Real byte progress from Homebrew's download queue

The download progress bar now shows Homebrew's own byte counter — e.g. `263.1 MB of 373.1 MB · 71%` — instead of a percent-plus-estimated size. v1.16 pinned `HOMEBREW_DOWNLOAD_CONCURRENCY=1` to get brew's single-line `#### NN.N%` bar (percentage only), and derived bytes from a `HEAD` request. This release enables brew's default parallel download queue, which prints a live status line with exact bytes: `⠋ Cask <name> (<ver>) ####  Downloading 263.1MB/373.1MB`.

That queue redraws each frame by moving the cursor to column 0 with a CHA control sequence (`ESC[0G`) rather than a bare carriage return, which is why a plain scrollback console previously couldn't render it (the frames piled up or vanished). The console model now translates `ESC[<n>G` to a carriage return before stripping the remaining ANSI (colours, cursor show/hide, synchronized-output `ESC[?2026h/l`, erase-line `ESC[K`), so each frame rewrites a single line in place — exactly like the old single-download bar. The progress parser gained a byte-counter branch (`Downloading X/Y` / `Downloaded X/Y`) that reads brew's real received/total figures (binary units) and the cask/formula name from the status line; these are authoritative, so no `HEAD` request is needed when they're present. The `HEAD`-estimate path remains as a fallback. The interactive `[y/n]` prompt handling is unchanged. Added byte-counter parser tests and verified against a real captured parallel-queue stream.

Optimized arm64 build verified; the built bundle reports version 1.17 (build 19).
