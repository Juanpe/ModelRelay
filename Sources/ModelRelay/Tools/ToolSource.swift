/// Where the tools of one tool set id come from. Steps name tool sets by id,
/// so `ToolKit`s and `HostToolKit`s share one set of ids.
enum ToolSource: Sendable {
    /// Requests defined in the kit.
    case requests(ToolKit)
    /// Tools a server offers, discovered when a step runs.
    case server(ToolKit)
    /// Tools the app wrote in Swift.
    case host(HostToolKit)
    /// The id names both a tool kit and a host tool kit: neither is used.
    case ambiguous(ToolKit, HostToolKit)
}

/// The executor's tool sets by id.
struct ToolSources: Sendable {
    private let sources: [String: ToolSource]

    /// The first kit with an id wins within each list, as before host tools.
    init(kits: [ToolKit], hostKits: [HostToolKit]) {
        var sources: [String: ToolSource] = [:]
        for kit in kits where sources[kit.id] == nil {
            sources[kit.id] = kit.server == nil ? .requests(kit) : .server(kit)
        }
        var hosts: Set<String> = []
        for host in hostKits where hosts.insert(host.id).inserted {
            switch sources[host.id] {
            case let .requests(kit), let .server(kit): sources[host.id] = .ambiguous(kit, host)
            default: sources[host.id] = .host(host)
            }
        }
        self.sources = sources
    }

    subscript(id: String) -> ToolSource? {
        sources[id]
    }

    /// The Codable kits, which recovery checkpoints fingerprint.
    var declaredKits: [ToolKit] {
        sources.values.compactMap { source in
            switch source {
            case let .requests(kit), let .server(kit), let .ambiguous(kit, _): kit
            case .host: nil
            }
        }
    }
}
