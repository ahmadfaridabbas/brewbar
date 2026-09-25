import SwiftUI

struct InstalledView: View {
    @ObservedObject var model: BrewModel
    @Environment(\.theme) private var theme
    private var searchMode: Bool { model.installedTabMode == "Search" }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Mode toggle: browse what's installed, or search Homebrew and install something new.
            Picker("Mode", selection: $model.installedTabMode) {
                Text("Installed").tag("Installed")
                Text("Search & Install").tag("Search")
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Installed tab mode")

            if searchMode { searchModeView } else { installedModeView }
        }.frame(height: 300)
        .onAppear { if !searchMode { model.loadInstalledIfNeeded() } }
        .onChange(of: model.ready) { _ in if !searchMode { model.loadInstalledIfNeeded() } }
        .onChange(of: model.installedTabMode) { _ in if !searchMode { model.loadInstalledIfNeeded() } }
    }

    // MARK: - Installed (browse local inventory)

    private var installedModeView: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                TextField("Search installed apps and formulae", text: $model.search).textFieldStyle(.plain)
                    .foregroundStyle(theme.text)
                    .accessibilityLabel("Search installed packages")
                Button { model.refreshInstalled() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy || !model.ready).help("Refresh installed packages")
                    .accessibilityLabel("Refresh installed packages")
            }.padding(9).background(theme.field, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(model.filteredPackages.count) packages · Homebrew only")
                Spacer()
                if model.inventoryStale { Text("Refresh to verify changes").foregroundStyle(theme.warning) }
            }.font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            if let error = model.inventoryError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let package = model.uninstallCandidate {
                confirmCard(title: "Uninstall \(package.name)?", icon: "trash",
                            body: "Homebrew will remove this package. Dependency checks remain enabled.",
                            command: "brew " + package.uninstallArguments.joined(separator: " ")) {
                    Button("Cancel") { model.uninstallCandidate = nil }
                    Button("Confirm Uninstall", role: .destructive) { model.uninstall(package) }
                        .disabled(model.busy || !model.ready)
                }
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    if model.loadingInventory {
                        ProgressView("Reading installed packages…").padding(30)
                    } else if model.filteredPackages.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "shippingbox").font(.title2)
                            Text(model.inventoryLoaded ? (model.search.isEmpty ? "No Homebrew packages installed" : "No matching packages") : "Your installed packages will appear here").font(.caption)
                            if !model.inventoryLoaded { Button("Load Installed Packages") { model.refreshInstalled() }.disabled(model.busy || !model.ready) }
                        }.foregroundStyle(theme.secondaryText).frame(maxWidth: .infinity).padding(25)
                    }
                    ForEach(model.filteredPackages) { package in
                        packageRow(icon: package.kind == "App" ? "app.dashed" : "shippingbox.fill",
                                   name: package.name, detail: package.detail,
                                   meta: "\(package.kind) · \(package.version)") {
                            Button("Uninstall", role: .destructive) { model.uninstallCandidate = package }
                                .controlSize(.small).disabled(model.busy || !model.ready || !package.canUninstall)
                                .accessibilityLabel("Uninstall \(package.name)")
                        }.help("\(package.token) · \(package.version)\n\(package.detail)")
                    }
                }
            }
        }
    }

    // MARK: - Search & Install

    private var searchModeView: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.secondaryText)
                TextField("Search Homebrew to install (press Return)", text: $model.searchQuery)
                    .textFieldStyle(.plain).foregroundStyle(theme.text)
                    .onSubmit { model.searchPackages(model.searchQuery) }
                    .accessibilityLabel("Search Homebrew packages to install")
                Button { model.searchPackages(model.searchQuery) } label: { Image(systemName: "return") }
                    .disabled(model.busy || !model.ready).help("Search Homebrew")
                    .accessibilityLabel("Run search")
            }.padding(9).background(theme.field, in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(model.searchResults.isEmpty ? "Search formulae and casks, then install" : "\(model.searchResults.count) result\(model.searchResults.count == 1 ? "" : "s")")
                Spacer()
                if model.inventoryStale { Text("Installed list updating…").foregroundStyle(theme.warning) }
            }.font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            if let error = model.searchError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let result = model.installCandidate {
                confirmCard(title: "Install \(result.name)?", icon: "arrow.down.circle",
                            body: result.kind == "App" ? "Homebrew will download and install this app. Some casks may prompt for your password." : "Homebrew will download and install this formula and its dependencies.",
                            command: "brew " + result.installArguments.joined(separator: " ")) {
                    Button("Cancel") { model.installCandidate = nil }
                    Button("Confirm Install") { model.install(result) }
                        .disabled(model.busy || !model.ready)
                }
            }
            ScrollView {
                LazyVStack(spacing: 7) {
                    if model.searching {
                        ProgressView("Searching Homebrew…").padding(30)
                    } else if model.searchResults.isEmpty && !model.searchPerformed {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass.circle").font(.title2)
                            Text("Find a formula or cask to install").font(.caption)
                            Text("Type a name and press Return.").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
                        }.foregroundStyle(theme.secondaryText).frame(maxWidth: .infinity).padding(25)
                    }
                    ForEach(model.searchResults) { result in
                        packageRow(icon: result.kind == "App" ? "app.dashed" : "shippingbox.fill",
                                   name: result.name, detail: result.detail,
                                   meta: "\(result.kind) · \(result.version)") {
                            if result.installed {
                                Label("Installed", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11)).foregroundStyle(theme.accent)
                                    .accessibilityLabel("\(result.name) is already installed")
                            } else {
                                Button("Install") { model.installCandidate = result }
                                    .controlSize(.small).disabled(model.busy || !model.ready || !result.valid)
                                    .accessibilityLabel("Install \(result.name)")
                            }
                        }.help("\(result.token) · \(result.version)\n\(result.detail)")
                    }
                }
            }
        }
    }

    // MARK: - Shared row / card builders

    @ViewBuilder private func packageRow<Trailing: View>(icon: String, name: String, detail: String, meta: String,
                                                         @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 19)).foregroundStyle(theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text(detail).font(.system(size: 10)).foregroundStyle(theme.secondaryText).lineLimit(1)
                Text(meta).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
        }.padding(10).background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.surfaceBorder))
    }

    @ViewBuilder private func confirmCard<Buttons: View>(title: String, icon: String, body: String, command: String,
                                                        @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            Text(body).font(.caption).foregroundStyle(theme.secondaryText)
            Text(command).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.text).textSelection(.enabled)
            HStack { Spacer(); buttons() }.controlSize(.small)
        }.padding(12).background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
