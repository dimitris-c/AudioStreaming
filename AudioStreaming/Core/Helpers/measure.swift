//
//  measure.swift
//  AudioStreaming
//
//  Created by Dimitrios Chatzieleftheriou on 31/10/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

func measure(name: String = "", block: () -> Void) {
    let started = ProcessInfo.processInfo.systemUptime
    block()
    print("diff for \(name): \(String(format: "%.6f", ProcessInfo.processInfo.systemUptime - started))")
}
