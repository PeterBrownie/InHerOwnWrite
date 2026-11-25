import Foundation

/// Who a name written on a page means.
public enum PersonResolution: Hashable, Sendable {
    /// One person, by the name she gave them or as written.
    case person(String)
    /// Only a first name is written, and two or more people have it: which one isn't known yet.
    case unsure(written: String, choices: [String])

    public var label: String {
        switch self {
        case .person(let name): return name
        case .unsure(let written, _): return "\(written) (unsure which)"
        }
    }

    public var isUnsure: Bool {
        if case .unsure = self { return true }
        return false
    }
}

/// The people named across the journals. When two people share a first name, she can give each page's name a
/// last name or initial ("Hannah K."). A page that names only the first name is then unsure until she says
/// which person it means. Names written in full ("Hannah Kim") count as people too.
public struct PeopleDirectory: Sendable {
    private let byFirstName: [String: [String]]
    private let assigned: [UUID: [String: String]]

    public init(pages: [PageInfo]) {
        var assigned: [UUID: [String: String]] = [:]
        var full: [String: [String: Int]] = [:]
        func note(_ name: String) {
            let tokens = WordTokenizer.tokens(in: name)
            guard tokens.count > 1 else { return }
            full[tokens[0].key, default: [:]][name, default: 0] += 1
        }
        for page in pages {
            guard let structure = page.structure else { continue }
            structure.names.forEach(note)
            if let people = structure.people, !people.isEmpty {
                assigned[page.id] = people
                people.values.forEach(note)
            }
        }
        // One spelling per person: the most used of the forms that read the same.
        byFirstName = full.mapValues { forms in
            var chosen: [String: (name: String, count: Int)] = [:]
            for (name, count) in forms {
                let key = Self.key(name)
                if let current = chosen[key], (current.count, name) >= (count, current.name) { continue }
                chosen[key] = (name, count)
            }
            return chosen.values.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        self.assigned = assigned
    }

    /// Case, accents, and possessives don't matter: "Hannah K." and "hannah k" are the same person.
    public static func key(_ name: String) -> String {
        WordTokenizer.tokens(in: name).map(\.key).joined(separator: " ")
    }

    /// Everyone known by a fuller name who shares this name's first name.
    public func people(sharingFirstNameWith written: String) -> [String] {
        guard let first = WordTokenizer.tokens(in: written).first else { return [] }
        let own = Self.key(written)
        return (byFirstName[first.key] ?? []).filter { Self.key($0) != own }
    }

    public func resolve(_ written: String, onPage pageID: UUID) -> PersonResolution {
        if let chosen = assigned[pageID]?[Self.key(written)] { return .person(chosen) }
        guard WordTokenizer.tokens(in: written).count == 1 else { return .person(written) }
        let choices = people(sharingFirstNameWith: written)
        return choices.count > 1 ? .unsure(written: written, choices: choices) : .person(written)
    }

    /// The names on one page, once each, with who they mean.
    public func people(on page: PageInfo) -> [(written: String, resolution: PersonResolution)] {
        var seen = Set<String>()
        return (page.structure?.names ?? []).compactMap { name in
            let key = Self.key(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return (name, resolve(name, onPage: page.id))
        }
    }
}
