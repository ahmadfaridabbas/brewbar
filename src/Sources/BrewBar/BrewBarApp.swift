import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: BrewModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.busy == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Homebrew is still running"
        alert.informativeText = "Use Stop in BrewBar and wait for the command to finish before quitting."
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
        return .terminateCancel
    }
}

enum AppInfo {
    /// Marketing version (CFBundleShortVersionString), with build number when available.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.28"
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "Version \(short) (\(build))"
        }
        return "Version \(short)"
    }
}

enum BrandImages {
    static let lightIcon = load("AppIconLight")
    static let darkIcon = load("AppIconDark")
    static func load(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: NSSize(width: 48, height: 48)) }
        return image
    }
    static func icon(dark: Bool) -> NSImage { dark ? darkIcon : lightIcon }

    static let appIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage(size: NSSize(width: 48, height: 48)) }
        return image
    }()
    static let menuBar: NSImage = {
        guard let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "BrewBar")!
        }
        if let retinaURL = Bundle.main.url(forResource: "MenuBarTemplate@2x", withExtension: "png"),
           let data = try? Data(contentsOf: retinaURL),
           let retina = NSBitmapImageRep(data: data) {
            retina.size = NSSize(width: 18, height: 18)
            image.addRepresentation(retina)
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    /// The menu-bar glyph, optionally badged with a small dot in the top-right when updates are
    /// pending. When `count == 0` (and not running) we return the plain template image so the OS
    /// tints it for light/dark menu bars as usual. When there's a badge we must draw in color (a
    /// template image can't carry a colored dot), so the result is a non-template composite: the
    /// base glyph is drawn as a filled template using the current control text color so it still
    /// looks native, then an amber dot is stamped on top.
    static func menuBarBadged(count: Int, running: Bool) -> NSImage {
        guard count > 0, !running else { return menuBar }
        let size = NSSize(width: 18, height: 18)
        let composite = NSImage(size: size)
        composite.lockFocus()
        // Draw the base glyph tinted to the menu-bar text color so it matches native template look.
        let tint = NSColor.controlTextColor
        if let tinted = menuBar.copy() as? NSImage {
            tinted.isTemplate = false
            tinted.lockFocus()
            tint.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.draw(in: NSRect(origin: .zero, size: size))
        } else {
            menuBar.draw(in: NSRect(origin: .zero, size: size))
        }
        // Amber dot in the top-right corner.
        let dotDiameter: CGFloat = 7
        let dotRect = NSRect(x: size.width - dotDiameter, y: size.height - dotDiameter,
                             width: dotDiameter, height: dotDiameter)
        NSColor(calibratedRed: 0.878, green: 0.584, blue: 0.184, alpha: 1).setFill()  // #e0952f
        NSBezierPath(ovalIn: dotRect).fill()
        composite.unlockFocus()
        composite.isTemplate = false  // keep the amber dot in color
        return composite
    }
}

@main struct BrewBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BrewModel()
    var body: some Scene {
        MenuBarExtra {
            Dashboard(model: model)
                .preferredColorScheme(model.preferredScheme)
                .onAppear { delegate.model = model; model.applyAppearance(); model.startBackgroundUpdateChecks() }
        } label: {
            Label {
                Text(menuBarTitle)
            } icon: {
                Image(nsImage: BrandImages.menuBarBadged(count: model.updateCount, running: model.busy))
            }
        }.menuBarExtraStyle(.window)
    }

    /// The menu-bar label text: shows a running state, else an update count when any are pending.
    private var menuBarTitle: String {
        if model.busy { return "BrewBar — Running" }
        if model.updateCount > 0 { return "BrewBar — \(model.updateCount) update\(model.updateCount == 1 ? "" : "s")" }
        return "BrewBar"
    }
}

struct Dashboard: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: BrewModel
    private var statusColor: Color { model.busy ? .orange : (model.failed ? .red : .green) }
    private var theme: Theme { Theme.resolve(model.appearanceMode, systemIsDark: colorScheme == .dark) }
    private var appearanceIcon: String {
        switch model.appearanceMode {
        case .paperyLight, .paperyDark: return "doc.plaintext"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        case .system: return colorScheme == .dark ? "moon.fill" : "sun.max.fill"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: BrandImages.icon(dark: colorScheme == .dark)).resizable().interpolation(.high)
                    .frame(width: 54, height: 54).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BrewBar").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
                    Text("A little care for your Homebrew.").foregroundStyle(theme.secondaryText)
                    Text(AppInfo.versionString)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityLabel("App \(AppInfo.versionString)")
                    if model.installingUpdate {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                            Text("\(model.updateInstallStage.isEmpty ? "Updating" : model.updateInstallStage) \(Int(model.updateInstallProgress * 100))%")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(theme.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(theme.accent)
                        .accessibilityLabel("Updating BrewBar, \(Int(model.updateInstallProgress * 100)) percent")
                    } else if model.appUpdateAvailable, let latest = model.latestAppVersion {
                        Button { model.installUpdate() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 9))
                                Text("Update to \(latest)")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(theme.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                        .help("Download and install BrewBar \(latest), then relaunch")
                        .accessibilityLabel("Update to BrewBar \(latest). Downloads, installs, and relaunches.")
                    }
                }
                Spacer()
                Menu {
                    if model.installingUpdate {
                        Text(model.updateInstallStage.isEmpty ? "Updating…" : "\(model.updateInstallStage) \(Int(model.updateInstallProgress * 100))%")
                    } else if model.appUpdateAvailable, let latest = model.latestAppVersion {
                        Button("Update to \(latest)") { model.installUpdate() }
                        Button("View Release Notes…") { model.openAppReleasePage() }
                    } else {
                        Button(model.checkingAppUpdate ? "Checking for Updates…" : "Check for Updates…") {
                            model.checkForAppUpdate(manual: true)
                        }.disabled(model.checkingAppUpdate)
                    }
                    if let status = model.appUpdateStatus {
                        Text(status)
                    }
                    Divider()
                    Button("Retry Homebrew Detection") { model.prepare() }.disabled(model.busy)
                    Link("Homebrew Documentation", destination: URL(string: "https://docs.brew.sh/Manpage")!)
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help("BrewBar options")
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut("w")
                .help("Close this panel; BrewBar stays in the menu bar")
                .accessibilityLabel("Close panel")
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut("q")
                .disabled(model.busy)
                .help(model.busy ? "Stop the running command before quitting" : "Quit BrewBar")
                .accessibilityLabel("Quit BrewBar")
            }
            HStack(spacing: 10) {
                Label("Appearance", systemImage: appearanceIcon)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.secondaryText)
                Spacer()
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }.pickerStyle(.menu).fixedSize().labelsHidden()
                    .accessibilityLabel("App appearance")
            }
            Picker("Section", selection: $model.selectedTab) {
                Text("Maintenance").tag("Maintenance")
                Text("Installed").tag("Installed")
                Text(model.updatesLoaded ? "Updates (\(model.updates.count))" : "Updates").tag("Updates")
            }.pickerStyle(.segmented).focusable(false).hideSegmentedFocusRing()
            if model.selectedTab == "Installed" {
                InstalledView(model: model)
            } else if model.selectedTab == "Updates" {
                UpdatesView(model: model)
            } else {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(BrewAction.all) { action in
                    Button { model.run(action) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: action.icon).font(.system(size: 19)).foregroundStyle(theme.accent).frame(width: 25, height: 25)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(action.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.text)
                                Text(action.detail).font(.system(size: 11)).foregroundStyle(theme.secondaryText).fixedSize(horizontal: false, vertical: true)
                                Text("brew \(action.command)").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.tertiaryText)
                            }
                            Spacer(minLength: 0)
                        }.frame(maxWidth: .infinity, minHeight: 67, alignment: .leading).padding(11)
                        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.surfaceBorder))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).disabled(model.busy || !model.ready)
                    .opacity(model.busy || !model.ready ? 0.55 : 1)
                    .accessibilityLabel("\(action.title). \(action.detail). Run brew \(action.command)")
                    .help("Run brew \(action.command)")
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down.square").font(.system(size: 17)).foregroundStyle(theme.accent).frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brewfile backup").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Save your setup, or restore it from a Brewfile.").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                }
                Spacer(minLength: 6)
                Button("Export") { model.exportBrewfile() }
                    .controlSize(.small).help("Save a Brewfile with brew bundle dump")
                Button("Restore") { model.chooseBrewfileToRestore() }
                    .controlSize(.small).help("Install from a Brewfile with brew bundle install")
            }.disabled(model.busy || !model.ready)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.surfaceBorder))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Brewfile backup. Export saves your setup; Restore installs from a Brewfile.")
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(theme.text)
                    Text(model.command).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle).foregroundStyle(theme.text).help(model.command)
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(model.status).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.text)
                }.padding(12)
                Divider()
                ConsoleOutput(output: model.output, follow: model.follow, theme: theme)
                    .frame(height: 140)
                Divider()
                if !model.downloads.isEmpty {
                    LiveDownloads(downloads: model.downloads, theme: theme)
                    Divider()
                }
                if model.awaitingInput {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(theme.accent)
                        Text(model.promptText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { model.answer(false) } label: { Text("No") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .keyboardShortcut(.cancelAction)
                            .help("Send “n” — abort the command")
                        Button { model.answer(true) } label: { Text("Yes") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                            .help("Send “y” — proceed")
                    }
                    .font(.system(size: 11)).padding(10)
                    .background(theme.accent.opacity(0.10))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(model.promptText). Press Yes to proceed or No to abort.")
                    Divider()
                }
                if let recovery = model.recovery, !model.busy {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(theme.warning)
                        Text(recovery.message)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.text).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { model.dismissRecovery() } label: { Text("Dismiss") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Hide this suggestion")
                        Button { model.performRecovery() } label: { Label(recovery.actionTitle, systemImage: recovery.actionSymbol) }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(!model.ready)
                            .help(recovery.actionHelp)
                    }
                    .font(.system(size: 11)).padding(10)
                    .background(theme.warning.opacity(0.12))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(recovery.message) \(recovery.actionTitle), or Dismiss.")
                    Divider()
                }
                if let restore = model.brewfileRestoreCandidate, !model.busy {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore from this Brewfile?").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                            Text(restore.lastPathComponent).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
                                .lineLimit(1).truncationMode(.middle).help(restore.path)
                        }
                        Spacer(minLength: 8)
                        Button { model.cancelRestoreBrewfile() } label: { Text("Cancel") }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button { model.confirmRestoreBrewfile() } label: { Label("Install", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(!model.ready)
                            .help("Run brew bundle install with the chosen Brewfile")
                    }
                    .font(.system(size: 11)).padding(10)
                    .background(theme.accent.opacity(0.10))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Restore from Brewfile \(restore.lastPathComponent). Install or Cancel.")
                    Divider()
                }
                HStack(spacing: 12) {
                    Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(model.output.isEmpty && model.downloads.isEmpty).help("Copy visible output")
                    Button { model.clear() } label: { Label("Clear", systemImage: "trash") }.disabled(model.output.isEmpty)
                    Toggle("Follow", isOn: $model.follow).toggleStyle(.checkbox).help("Scroll to new output automatically")
                    Spacer()
                    Button(role: .destructive) { model.stop() } label: { Label(model.stopping ? "Stopping" : "Stop", systemImage: "stop.fill") }
                        .disabled(!model.busy || !model.ready || model.stopping)
                }.font(.system(size: 11)).controlSize(.small).padding(10).foregroundStyle(theme.text)
            }.background(theme.consoleBackground, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.consoleBorder))
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.brewPath ?? "Looking for Homebrew…").font(.system(size: 10, design: .monospaced))
                    if let start = model.started {
                        HStack(spacing: 4) {
                            Text("Started \(start.formatted(date: .omitted, time: .shortened))")
                            if let code = model.exitCode { Text("· Exit \(code)") }
                            if let end = model.finished { Text("· \(Int(end.timeIntervalSince(start)))s") }
                            else { Text(start, style: .timer) }
                        }.font(.system(size: 10))
                    }
                }.foregroundStyle(theme.secondaryText)
                Spacer()
                if !model.ready && !model.busy { Button("Retry") { model.prepare() } }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.busy ? "Safe to close this panel" : "One command at a time").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                    Text("MIT License · © 2026 Ahmad Farid Abbas").font(.system(size: 9)).foregroundStyle(theme.tertiaryText)
                }
            }
        }.padding(20).frame(width: 550)
        .background(themeBackground)
        .environment(\.theme, theme)
        .tint(theme.accent)
        .onChange(of: colorScheme) { scheme in model.applyAppearance() }
    }

    /// The root surface: native modes keep the translucent material; Papery uses a solid paper
    /// fill with a very faint procedural grain overlay for a stationery feel.
    @ViewBuilder private var themeBackground: some View {
        if theme.usesMaterial {
            Rectangle().fill(.regularMaterial)
        } else {
            theme.background.overlay(PaperGrain(opacity: theme.grainOpacity))
        }
    }
}

/// A lightweight, static paper-grain overlay. Rendered once as a stack of faint tiled speckles
/// via a Canvas so it costs nothing per frame. Kept extremely subtle so text stays crisp.
struct PaperGrain: View {
    let opacity: Double
    var body: some View {
        Canvas { context, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func rand() -> Double {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return Double(seed % 10_000) / 10_000
            }
            let count = Int((size.width * size.height) / 900)
            for _ in 0..<count {
                let x = rand() * size.width
                let y = rand() * size.height
                let s = 0.5 + rand() * 0.8
                let dark = rand() > 0.5
                let shade = dark ? Color.black : Color.white
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: s, height: s)),
                             with: .color(shade.opacity(0.35)))
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The console's scrolling text, backed by an `NSTextView` inside an `NSScrollView`.
///
/// A pure-SwiftUI `Text` (especially a large, selectable one) rendered inside a `ScrollView`
/// intermittently blanks out mid-scroll and re-lays-out the whole string on every `output`
/// mutation — which, during a `brew upgrade` with a live download counter updating ~10×/second,
/// starves the main thread and makes the menu-bar UI feel stuck. AppKit's `NSTextView` handles
/// large, incrementally-appended, selectable monospaced logs without blanking and only re-lays-out
/// the delta, so it fixes both the blank-on-scroll and the download-time lag.
struct ConsoleOutput: NSViewRepresentable {
    let output: String
    let follow: Bool
    let theme: Theme

    private static let placeholder = "Choose an action above.\nLive command output will appear here."
    private var isEmpty: Bool { output.isEmpty }
    private var displayText: String { isEmpty ? Self.placeholder : output }
    private var font: NSFont {
        NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let color = isEmpty ? NSColor(theme.secondaryText) : NSColor(theme.text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]

        // Only rewrite storage when the text actually changed. This keeps typing/selection smooth
        // and avoids re-laying-out the whole log on unrelated view updates (theme, follow toggle).
        if context.coordinator.lastText != displayText {
            context.coordinator.lastText = displayText
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: displayText, attributes: attributes)
            )
        } else {
            // Text unchanged but colors/theme may have: refresh attributes cheaply.
            textView.textStorage?.addAttributes(
                attributes,
                range: NSRange(location: 0, length: textView.textStorage?.length ?? 0)
            )
        }

        // Auto-scroll to the end only while Follow is on, and only when there's real output.
        if follow && !isEmpty {
            textView.scrollToEndOfDocument(nil)
        }
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastText: String?
    }
}

/// The console's pinned live-download block (Option A: rendered outside the scrolling console so it
/// stays visible regardless of the Follow toggle). Homebrew's parallel download queue reports several
/// packages at once; this shows one row per package — spinner/✓, name, an inline mini progress bar,
/// percent, and brew's byte counter — rebuilt from the model's keyed `downloads`. Completed rows show
/// a green check at 100% and stay until every download finishes (then the model commits the block to
/// the log and it disappears). No name/bytes mismatch is possible because each row is its own entry.
struct LiveDownloads: View {
    let downloads: [DownloadEntry]
    let theme: Theme

    private var doneCount: Int { downloads.filter { $0.done }.count }
    private var title: String {
        let n = downloads.count
        return n == 1 ? "Downloading 1 item" : "Downloading \(n) items"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(theme.accent)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                Spacer(minLength: 8)
                Text("\(doneCount)/\(downloads.count) done")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.secondaryText)
                    .monospacedDigit()
            }
            ForEach(downloads) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.done ? "checkmark.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(entry.done ? Color.green : theme.accent)
                        .frame(width: 14)
                    Text(entry.name)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: 150, alignment: .leading)
                        .help(entry.name)
                    ProgressView(value: entry.fraction)
                        .progressViewStyle(.linear)
                        .tint(entry.done ? Color.green : theme.accent)
                        .frame(maxWidth: .infinity)
                    Text(entry.byteSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 130, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(entry.name). \(entry.done ? "Downloaded" : "Downloading"). \(entry.byteSummary).")
            }
        }
        .padding(10)
        .background(theme.accent.opacity(0.08))
        .accessibilityElement(children: .contain)
    }
}


/// Suppresses the AppKit keyboard focus ring on a SwiftUI segmented `Picker`.
///
/// SwiftUI's `.segmented` picker style is backed by an `NSSegmentedControl`. When it (or its window)
/// takes first responder, AppKit draws a blue focus ring around the selected segment. SwiftUI's
/// `.focusable(false)` doesn't reliably stop this, so we reach the backing control through the view
/// hierarchy and set `focusRingType = .none`. Rendered as a zero-size background so it never affects
/// layout.
private struct SegmentedFocusRingSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        DispatchQueue.main.async { Self.disableFocusRing(near: probe) }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.disableFocusRing(near: nsView) }
    }

    /// Walk up to the nearest common ancestor and back down to find sibling segmented controls.
    private static func disableFocusRing(near probe: NSView) {
        guard let container = probe.superview else { return }
        applyRecursively(from: container)
    }

    private static func applyRecursively(from view: NSView) {
        if let segmented = view as? NSSegmentedControl {
            segmented.focusRingType = .none
        }
        for subview in view.subviews { applyRecursively(from: subview) }
    }
}

extension View {
    /// Removes the blue keyboard focus ring drawn around a `.segmented` picker's selected segment.
    func hideSegmentedFocusRing() -> some View {
        background(SegmentedFocusRingSuppressor().frame(width: 0, height: 0))
    }
}
