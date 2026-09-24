import SwiftUI
import Combine

/// Coalesces a store transaction into one view invalidation after its values
/// have committed. Hidden surfaces read the latest state when shown again.
final class StoreInvalidation: ObservableObject {
    private var subscription: AnyCancellable?
    private var owner: ObjectIdentifier?
    private var pending = false
    var visible = true

    func connect(owner: AnyObject, changes: @autoclosure () -> [AnyPublisher<Void, Never>]) {
        let identity = ObjectIdentifier(owner)
        guard self.owner != identity else { return }
        self.owner = identity
        subscription = Publishers.MergeMany(changes()).sink { [weak self] in
            guard let self, !self.pending, self.visible else { return }
            self.pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                if self.visible { self.objectWillChange.send() }
            }
        }
    }
}

struct ProviderFields: OptionSet {
    let rawValue: Int
    static let configuration = Self(rawValue: 1 << 0)
    static let usage = Self(rawValue: 1 << 1)
    static let sessions = Self(rawValue: 1 << 2)
    static let heartbeats = Self(rawValue: 1 << 3)
    static let expansion = Self(rawValue: 1 << 4)
}

private struct ProviderSourceKey: EnvironmentKey {
    static let defaultValue: ProviderStore? = nil
}
extension EnvironmentValues {
    var providerSource: ProviderStore? {
        get { self[ProviderSourceKey.self] }
        set { self[ProviderSourceKey.self] = newValue }
    }
}

/// A non-observing store reference plus a field-scoped invalidation signal.
/// Actions still operate on the canonical store; no duplicate data is kept.
@propertyWrapper struct ProviderState: DynamicProperty {
    @Environment(\.providerSource) private var source
    @Environment(\.surfaceIsVisible) private var visible
    @StateObject private var invalidation = StoreInvalidation()
    private let fields: ProviderFields
    private var explicitStore: ProviderStore?

    init(_ fields: ProviderFields, store: ProviderStore? = nil) {
        self.fields = fields
        self.explicitStore = store
    }

    var wrappedValue: ProviderStore {
        guard let store = explicitStore ?? source else {
            preconditionFailure("ProviderState requires providerSource")
        }
        return store
    }

    var projectedValue: StoreBindings<ProviderStore> { StoreBindings(store: wrappedValue) }

    mutating func update() {
        invalidation.visible = visible
        invalidation.connect(owner: wrappedValue, changes: wrappedValue.viewChanges(fields))
    }
}

@dynamicMemberLookup struct StoreBindings<Store: AnyObject> {
    let store: Store
    subscript<Value>(dynamicMember path: ReferenceWritableKeyPath<Store, Value>) -> Binding<Value> {
        Binding(get: { store[keyPath: path] }, set: { store[keyPath: path] = $0 })
    }
}

extension ProviderStore {
    func viewChanges(_ fields: ProviderFields) -> [AnyPublisher<Void, Never>] {
        func changes<T: Equatable>(_ publisher: Published<T>.Publisher) -> AnyPublisher<Void, Never> {
            publisher.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
        var out: [AnyPublisher<Void, Never>] = []
        if fields.contains(.configuration) {
            out += [changes($providers), changes($activeProviderID), changes($currentEnv),
                    changes($hasSettingsFile), changes($errorMessage), changes($importSummary),
                    changes($balanceAmounts), changes($supplierBalances), changes($balanceLoading),
                    changes($balanceText), changes($collapsedProviderIDs)]
        }
        if fields.contains(.usage) {
            out += [changes($usageStats), changes($usageDays), changes($usageBySource),
                    changes($usageDaysBySource), changes($usagePeriod), changes($usageReferenceDate), changes($usageLoading)]
        }
        if fields.contains(.sessions) {
            out += [changes($sessions), changes($cursorSessions), changes($externalSessions)]
        }
        if fields.contains(.heartbeats) { out.append(changes($heartbeats)) }
        if fields.contains(.expansion) { out += [changes($expandedSessionPIDs), changes($cursorExpanded)] }
        return out
    }
}
