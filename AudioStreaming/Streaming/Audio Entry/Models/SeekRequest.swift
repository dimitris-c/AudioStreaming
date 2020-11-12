//
//  Created by Dimitrios Chatzieleftheriou on 25/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class SeekRequest {
    let lock = UnfairLock()
    var requested: Bool = false
    var version = Protected<Int>(0)
    var time: Double = 0
}
