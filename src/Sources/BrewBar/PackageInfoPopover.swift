import SwiftUI
import AppKit

/// The content of a per-package info popover (Feature 2). Reads the model's fetched `packageInfo`
/// (or its loading/error state) and renders description, version, dependencies, install size, and
/// caveats, plus a homepage link that opens in the default browser.
struct PackageInfoPopover: View {
    @ObservedObject var model: BrewModel
    @Environment(\.theme) private var theme
    /// Row name to show as the title while detail is still loading.
    let fallbackName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.infoLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("Loading \(fallbackName)…").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = model.infoError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red)
            } else if let info = model.packageInfo {
                content(info)
            } else {
                Text("No details.").font(.system(size: 12)).foregroundStyle(theme.secondaryText)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder private func content(_ info: PackageInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: info.kind == "App" ? "app.dashed" : "shippingbox.fill").foregroundStyle(theme.accent)
                Text(info.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(info.kind) · \(info.version)").font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.secondaryText)
            }
            if !info.description.isEmpty {
                Text(info.description).font(.system(size: 12)).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let size = info.installSize {
                detailRow(label: "Size", value: size)
            }
            if !info.dependencies.isEmpty {
                detailRow(label: "Dependencies", value: info.dependencies.joined(separator: ", "))
            }
            if let caveats = info.caveats {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Caveats").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondaryText)
                    Text(caveats).font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8).background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if info.homepageIsValid, let url = URL(string: info.homepage) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open homepage", systemImage: "safari").font(.system(size: 11))
                }.buttonStyle(.link).help(info.homepage)
                .accessibilityLabel("Open homepage for \(info.name) in browser")
            }
        }
    }

    @ViewBuilder private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.secondaryText).frame(width: 90, alignment: .leading)
            Text(value).font(.system(size: 11)).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
