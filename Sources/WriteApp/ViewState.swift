import SwiftUI

/// Wraps SwiftUI's `State` without its macro form, whose compiler plugin ships with Xcode
/// but not with the Command Line Tools this app is built with.
@propertyWrapper
struct ViewState<Value>: DynamicProperty {
    private var storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    init() where Value: ExpressibleByNilLiteral {
        storage = State(initialValue: nil)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> {
        storage.projectedValue
    }
}
