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
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.15"
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
}

@main struct BrewBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BrewModel()
    var body: some Scene {
        MenuBarExtra {
            Dashboard(model: model)
                .preferredColorScheme(model.preferredScheme)
                .onAppear { delegate.model = model; model.applyAppearance() }
        } label: {
            Label {
                Text(model.busy ? "BrewBar — Running" : "BrewBar")
            } icon: {
                Image(nsImage: BrandImages.menuBar)
            }
        }.menuBarExtraStyle(.window)
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
                }
                Spacer()
                Menu {
                    Button("Retry Homebrew Detection") { model.prepare() }.disabled(model.busy)
                    Link("Homebrew Documentation", destination: URL(string: "https://docs.brew.sh/Manpage")!)
                    Divider()
                    Button("Quit BrewBar") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).frame(width: 28).help("BrewBar options")
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered).controlSize(.small)
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
            }.pickerStyle(.segmented)
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
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ConsoleOutput(output: model.output, theme: theme)
                            Color.clear.frame(height: 1).id("end")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.frame(height: 140)
                    .onChange(of: model.output) { _ in if model.follow { proxy.scrollTo("end", anchor: .bottom) } }
                    .onChange(of: model.follow) { enabled in if enabled { proxy.scrollTo("end", anchor: .bottom) } }
                }
                Divider()
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
                HStack(spacing: 12) {
                    Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }.disabled(model.output.isEmpty).help("Copy visible output")
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

/// The console's scrolling text. Extracted into its own view so the type-checker doesn't choke on
/// the empty-state ternary combined with theme colors.
struct ConsoleOutput: View {
    let output: String
    let theme: Theme
    private var isEmpty: Bool { output.isEmpty }
    private var text: String { isEmpty ? "Choose an action above.\nLive command output will appear here." : output }
    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced)).lineSpacing(4)
            .foregroundStyle(isEmpty ? theme.secondaryText : theme.text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
