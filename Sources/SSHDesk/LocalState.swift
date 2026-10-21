import SwiftUI

/// Thay thế `@State`: SDK hiện tại khai báo `@State` là macro (SwiftUIMacros) mà Command Line Tools
/// không có plugin tương ứng, nên dùng struct `State` trực tiếp qua property wrapper này.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var state: State<Value>

    init(wrappedValue: Value) {
        state = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
