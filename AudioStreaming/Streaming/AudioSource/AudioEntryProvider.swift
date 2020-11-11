//
//  AudioEntryProvider.swift
//  AudioStreaming
//
//  Created by Dimitrios Chatzieleftheriou on 11/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

protocol AudioEntryProviding {
    func provideAudioEntry(url: URL, headers: [String: String]) -> AudioEntry
    func provideAudioEntry(url: URL) -> AudioEntry
}

final class AudioEntryProvider: AudioEntryProviding {
    private let networkingClient: NetworkingClient
    private let underlyingQueue: DispatchQueue
    private let outputAudioFormat: AVAudioFormat

    init(networkingClient: NetworkingClient,
         underlyingQueue: DispatchQueue,
         outputAudioFormat: AVAudioFormat) {
        self.networkingClient = networkingClient
        self.underlyingQueue = underlyingQueue
        self.outputAudioFormat = outputAudioFormat
    }

    func provideAudioEntry(url: URL, headers: [String: String]) -> AudioEntry {
        let source = provideAudioSource(url: url, headers: headers)
        return AudioEntry(source: source,
                          entryId: AudioEntryId(id: url.absoluteString),
                          outputAudioFormat: outputAudioFormat)
    }

    func provideAudioEntry(url: URL) -> AudioEntry {
        let source = provideAudioSource(url: url, headers: [:])
        return AudioEntry(source: source,
                          entryId: AudioEntryId(id: url.absoluteString),
                          outputAudioFormat: outputAudioFormat)
    }

    func provideAudioSource(url: URL, headers: [String: String]) -> AudioStreamSource {
        RemoteAudioSource(networking: networkingClient,
                          url: url,
                          underlyingQueue: underlyingQueue,
                          httpHeaders: headers)
    }
}
