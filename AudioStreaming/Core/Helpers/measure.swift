//
//  measure.swift
//  AudioStreaming
//
//  Created by Vasyl Nadtochii on 01.04.2024
//

import Foundation

func measure(name: String = "", block: () -> Void) {
    let started = ProcessInfo.processInfo.systemUptime
    block()
    print("diff for \(name): \(String(format: "%.6f", ProcessInfo.processInfo.systemUptime - started))")
}
