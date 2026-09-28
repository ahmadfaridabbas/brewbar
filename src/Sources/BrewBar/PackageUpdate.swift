import Foundation

struct PackageUpdate: Identifiable, Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    let pinned: Bool
    var kind = "Formula"
    var id: String { kind + ":" + name }
    var valid: Bool { name.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil }
    /// A targeted upgrade command for this package. Casks get `--force`: a per-package
    /// `brew upgrade --cask <name>` refuses (`It seems there is already an App at '…'`) when a
    /// stale `.app` from the previous version is still in the Caskroom — common for self-updating
    /// apps (WhatsApp, Chrome, …). Homebrew's auto-upgrade path (a bare `brew upgrade`, used by
    /// Upgrade All) replaces such casks cleanly; `--force` makes the targeted single-package upgrade
    /// behave the same way instead of hitting that dead-end. Formulae never carry a `.app` artifact,
    /// so they stay plain (no `--force`).
    var arguments: [String] {
        kind == "App"
            ? ["upgrade", "--cask", "--force", name]
            : ["upgrade", "--formula", name]
    }
    enum CodingKeys: String, CodingKey { case name, installedVersions = "installed_versions", currentVersion = "current_version", pinned }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let list = try? c.decode([String].self, forKey: .installedVersions) { installedVersions = list }
        else { installedVersions = [try c.decode(String.self, forKey: .installedVersions)] }
        currentVersion = try c.decode(String.self, forKey: .currentVersion)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
    static func parse(_ data: Data) throws -> [PackageUpdate] {
        struct Response: Decodable { let formulae: [PackageUpdate]; let casks: [PackageUpdate] }
        let response = try JSONDecoder().decode(Response.self, from: JSONExtraction.object(from: data))
        return (response.formulae + response.casks.map { var p = $0; p.kind = "App"; return p })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Homebrew sometimes writes human-readable progress to stdout before its JSON payload
/// (for example `==> Downloading Homebrew API data` when its API cache is cold). That text
/// lands in the same capture file as the JSON and breaks a strict decode. This trims the
/// bytes down to the outermost `{ ... }` object so parsing tolerates such preambles.
enum JSONExtraction {
    static func object(from data: Data) -> Data {
        guard let start = data.firstIndex(of: UInt8(ascii: "{")),
              let end = data.lastIndex(of: UInt8(ascii: "}")),
              start <= end else { return data }
        return data.subdata(in: start..<(data.index(after: end)))
    }
}
