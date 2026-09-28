//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

/// A convenient type that holds tasks in a two-way manner, such as `URLSessionTask` to `NetworkDataStream` and reversed
struct BiMap<Left, Right> where Left: Hashable, Right: Hashable {
    private var leftToRight: [Left: Right] = [:]
    private var rightToLeft: [Right: Left] = [:]

    var isEmpty: Bool {
        leftValues.isEmpty && rightValues.isEmpty
    }

    var leftValues: [Left] {
        leftToRight.lazy.map(\.key)
    }

    var rightValues: [Right] {
        leftToRight.lazy.map(\.value)
    }

    @discardableResult
    mutating func removeValue(forLeft left: Left) -> Right? {
        guard let right = leftToRight.removeValue(forKey: left) else { return nil }
        rightToLeft.removeValue(forKey: right)
        return right
    }

    @discardableResult
    mutating func removeValue(forRight right: Right) -> Left? {
        guard let left = rightToLeft.removeValue(forKey: right) else { return nil }
        leftToRight.removeValue(forKey: left)
        return left
    }

    subscript(_ left: Left) -> Right? {
        get { leftToRight[left] }
        set {
            guard let newValue = newValue else {
                guard removeValue(forLeft: left) != nil else {
                    assertionFailure("inconsistency error: no right value found for left key")
                    return
                }
                return
            }
            leftToRight[left] = newValue
            rightToLeft[newValue] = left
        }
    }

    subscript(_ right: Right) -> Left? {
        get { rightToLeft[right] }
        set {
            guard let newValue = newValue else {
                guard removeValue(forRight: right) != nil else {
                    assertionFailure("inconsistency error: no left value found for right key")
                    return
                }
                return
            }

            rightToLeft[right] = newValue
            leftToRight[newValue] = right
        }
    }
}
