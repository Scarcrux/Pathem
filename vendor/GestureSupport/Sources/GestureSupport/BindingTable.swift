public struct GestureBindingValue<Action: Sendable>: Sendable {
    public let action: Action
    public let disabled: Bool
    public init(_ action: Action, disabled: Bool = false) {
        self.action = action
        self.disabled = disabled
    }
}

public enum BindingResolution<Action: Sendable, Failure: Sendable>: Sendable {
    case candidate(Action)
    case unbound, disabled
    case unavailable(Failure)
}

/// Disabled overrides suppress defaults. Eligibility and action execution stay
/// with the host app; the table only supplies a preview/lookup candidate.
public struct BindingTable<Input: Hashable & Sendable, Action: Sendable>: Sendable {
    private let defaults: [Input: GestureBindingValue<Action>]
    private let overrides: [Input: GestureBindingValue<Action>]
    public init(
        defaults: [Input: GestureBindingValue<Action>],
        overrides: [Input: GestureBindingValue<Action>] = [:]
    ) {
        self.defaults = defaults
        self.overrides = overrides
    }
    public func resolve<Failure: Sendable>(_ input: Input, eligibility: (Action) -> Failure?)
        -> BindingResolution<Action, Failure>
    {
        guard let binding = overrides[input] ?? defaults[input] else { return .unbound }
        guard !binding.disabled else { return .disabled }
        if let reason = eligibility(binding.action) { return .unavailable(reason) }
        return .candidate(binding.action)
    }
    public var effectiveBindings: [Input: Action] {
        defaults.merging(overrides) { _, override in override }.compactMapValues {
            $0.disabled ? nil : $0.action
        }
    }
}

extension BindingResolution: Equatable where Action: Equatable, Failure: Equatable {}
