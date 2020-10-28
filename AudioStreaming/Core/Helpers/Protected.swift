//
//  Created by Dimitrios Chatzieleftheriou on 21/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

internal final class Protected<Value> {
    var value: Value { lock.around { _value } }

    private let lock = UnfairLock()
    private var _value: Value

    init(_ value: Value) {
        _value = value
    }

    func read<Element>(_ closure: (Value) -> Element) -> Element {
        lock.around { closure(self._value) }
    }

    @discardableResult
    func write<Element>(_ closure: (inout Value) -> Element) -> Element {
        lock.around { closure(&self._value) }
    }
}
