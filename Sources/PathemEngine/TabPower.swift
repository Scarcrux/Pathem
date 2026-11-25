import Foundation

/// Everything the app needs to bring a tab back: where it was, how it was viewed, whether it was
/// locked, and where Back and Forward led. Tolerant decoding so an older or hand-edited file
/// restores what it can.
public struct TabSnapshot: Codable, Sendable, Equatable {
    public var path: String
    public var format: ViewFormat?
    public var locked: Bool
    public var back: [String]
    public var forward: [String]

    public init(
        path: String, format: ViewFormat? = nil, locked: Bool = false, back: [String] = [],
        forward: [String] = []
    ) {
        self.path = path
        self.format = format
        self.locked = locked
        self.back = back
        self.forward = forward
    }

    private enum CodingKeys: String, CodingKey { case path, format, locked, back, forward }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        format = try? c.decode(ViewFormat.self, forKey: .format)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        back = try c.decodeIfPresent([String].self, forKey: .back) ?? []
        forward = try c.decodeIfPresent([String].self, forKey: .forward) ?? []
    }
}

/// The last few closed tabs of one pane, newest on top.
public struct ClosedTabStack: Codable, Sendable, Equatable {
    public static let defaultLimit = 20
    public private(set) var items: [TabSnapshot] = []
    public let limit: Int

    public init(limit: Int = ClosedTabStack.defaultLimit) { self.limit = max(1, limit) }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public mutating func push(_ snapshot: TabSnapshot) {
        items.append(snapshot)
        if items.count > limit { items.removeFirst(items.count - limit) }
    }

    public mutating func pop() -> TabSnapshot? { items.popLast() }

    /// The newest closed tab whose folder still passes `exists`; stale ones met on the way are
    /// dropped, so a deleted folder never traps Reopen.
    public mutating func popRestorable(exists: (String) -> Bool) -> TabSnapshot? {
        while let top = items.popLast() {
            if exists(top.path) { return top }
        }
        return nil
    }
}

/// Lock rules for tabs, as pure functions over the lock flags.
public enum TabLockPolicy {
    public enum Navigation: Sendable, Equatable { case inPlace, newTab }

    /// A locked tab keeps its folder: going anywhere else opens a new tab.
    public static func navigation(locked: Bool, current: URL, target: URL) -> Navigation {
        guard locked else { return .inPlace }
        return current.standardizedFileURL.path == target.standardizedFileURL.path
            ? .inPlace : .newTab
    }

    public static func canClose(_ locks: [Bool], index: Int) -> Bool {
        locks.indices.contains(index) && !locks[index]
    }

    /// The tabs "Close Other Tabs" removes: everything except the kept tab and locked tabs.
    public static func indicesToCloseOthers(_ locks: [Bool], keeping: Int) -> [Int] {
        locks.indices.filter { $0 != keeping && !locks[$0] }
    }

    /// Lock flags padded with false or trimmed to the tab count (older sessions have none).
    public static func normalized(_ locks: [Bool], count: Int) -> [Bool] {
        Array((locks + Array(repeating: false, count: max(0, count - locks.count))).prefix(count))
    }
}

/// Most-recently-used order of tab identities, newest first.
public struct TabSwitcherOrder<ID: Hashable & Sendable>: Sendable {
    public private(set) var order: [ID] = []
    public init() {}

    public mutating func touch(_ id: ID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    public mutating func remove(_ id: ID) { order.removeAll { $0 == id } }

    /// Drop tabs that are gone; tabs never touched trail in their given order.
    public mutating func sync(live: [ID]) {
        let set = Set(live)
        order.removeAll { !set.contains($0) }
        let known = Set(order)
        order.append(contentsOf: live.filter { !known.contains($0) })
    }
}

/// The highlighted entry of an open switcher. Forward starts on the previous tab (index 1 of the
/// MRU list); reverse starts at the far end.
public struct TabSwitcherSelection<ID: Hashable & Sendable>: Sendable, Equatable {
    public let entries: [ID]
    public private(set) var selected: Int

    public init?(order: [ID], reverse: Bool) {
        guard order.count >= 2 else { return nil }
        entries = order
        selected = reverse ? order.count - 1 : 1
    }

    public var chosen: ID { entries[selected] }

    public mutating func advance(reverse: Bool) {
        let n = entries.count
        selected = (selected + (reverse ? n - 1 : 1)) % n
    }
}

/// A named set of tabs for both panes.
public struct TabGroup: Codable, Sendable, Equatable {
    public var name: String
    public var left: [TabSnapshot]
    public var leftActive: Int
    public var right: [TabSnapshot]
    public var rightActive: Int

    public init(
        name: String, left: [TabSnapshot], leftActive: Int, right: [TabSnapshot], rightActive: Int
    ) {
        self.name = name
        self.left = left
        self.leftActive = leftActive
        self.right = right
        self.rightActive = rightActive
    }

    private enum CodingKeys: String, CodingKey { case name, left, leftActive, right, rightActive }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        left = try c.decodeIfPresent([TabSnapshot].self, forKey: .left) ?? []
        leftActive = try c.decodeIfPresent(Int.self, forKey: .leftActive) ?? 0
        right = try c.decodeIfPresent([TabSnapshot].self, forKey: .right) ?? []
        rightActive = try c.decodeIfPresent(Int.self, forKey: .rightActive) ?? 0
    }
}

/// The saved tab groups (tab-groups.json). Names are unique ignoring case.
public struct TabGroupStore: Codable, Sendable, Equatable {
    public private(set) var groups: [TabGroup] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case groups }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
    }

    private func index(of name: String) -> Int? {
        groups.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public func group(named name: String) -> TabGroup? { index(of: name).map { groups[$0] } }

    /// Add a group, replacing one of the same name.
    public mutating func save(_ group: TabGroup) {
        if let i = index(of: group.name) { groups.remove(at: i) }
        groups.append(group)
    }

    @discardableResult
    public mutating func rename(_ old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index(of: old) else { return false }
        if let other = index(of: trimmed), other != i { return false }
        groups[i].name = trimmed
        return true
    }

    public mutating func delete(named name: String) {
        if let i = index(of: name) { groups.remove(at: i) }
    }
}
