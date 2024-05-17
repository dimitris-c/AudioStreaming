import SwiftUI

struct PrefersStackNavigationEnvironmentKey: EnvironmentKey {
    static var defaultValue: Bool = false
}

extension EnvironmentValues {
    var prefersStackNavigation: Bool {
        get { self[PrefersStackNavigationEnvironmentKey.self] }
        set { self[PrefersStackNavigationEnvironmentKey.self] = newValue }
    }
}

#if os(iOS)
extension PrefersStackNavigationEnvironmentKey: UITraitBridgedEnvironmentKey {
    static func read(from traitCollection: UITraitCollection) -> Bool {
        return traitCollection.userInterfaceIdiom == .phone || traitCollection.userInterfaceIdiom == .tv
    }

    static func write(to mutableTraits: inout UIMutableTraits, value: Bool) {
        // Do not write.
    }
}
#endif
