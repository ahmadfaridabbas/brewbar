import SwiftUI

struct InstalledView: View {
    @ObservedObject var model: BrewModel
    @Environment(\.theme) private var theme
    var body: some View {
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
                VStack(alignment: .leading, spacing: 8) {
                    Label("Uninstall \(package.name)?", systemImage: "trash")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                    Text("Homebrew will remove this package. Dependency checks remain enabled.")
                        .font(.caption).foregroundStyle(theme.secondaryText)
                    Text("brew \(package.uninstallArguments.joined(separator: " "))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.text).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Cancel") { model.uninstallCandidate = nil }
                        Button("Confirm Uninstall", role: .destructive) { model.uninstall(package) }
                            .disabled(model.busy || !model.ready)
                    }.controlSize(.small)
                }.padding(12).background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
                        HStack(spacing: 10) {
                            Image(systemName: package.kind == "App" ? "app.dashed" : "shippingbox.fill")
                                .font(.system(size: 19)).foregroundStyle(theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                                Text(package.detail).font(.system(size: 10)).foregroundStyle(theme.secondaryText).lineLimit(1)
                                Text("\(package.kind) · \(package.version)").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Button("Uninstall", role: .destructive) { model.uninstallCandidate = package }
                                .controlSize(.small).disabled(model.busy || !model.ready || !package.canUninstall)
                                .accessibilityLabel("Uninstall \(package.name)")
                        }.padding(10).background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.surfaceBorder))
                        .help("\(package.token) · \(package.version)\n\(package.detail)")
                    }
                }
            }
        }.frame(height: 270)
        .onAppear { model.loadInstalledIfNeeded() }
        .onChange(of: model.ready) { _ in model.loadInstalledIfNeeded() }
    }
}
