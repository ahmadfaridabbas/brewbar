import Foundation

struct PackageUpdate: Identifiable, Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String
    let pinned: Bool
    var kind = "Formula"
    var id: String { kind + ":" + name }
    var valid: Bool { name.range(of: "^[A-Za-z0-9][A-Za-z0-9@+._/-]*$", options: .regularExpression) != nil }
    var arguments: [String] { ["upgrade", kind == "App" ? "--cask" : "--formula", name] }
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
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.formulae + response.casks.map { var p = $0; p.kind = "App"; return p })
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
