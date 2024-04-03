//
//  Created by Dimitrios Chatzieleftheriou on 11/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AVFoundation

final class FileAudioSource: NSObject, CoreAudioStreamSource {
    weak var delegate: AudioStreamSourceDelegate?

    var underlyingQueue: DispatchQueue

    var position: Int
    var length: Int

    var audioFileHint: AudioFileTypeID {
        audioFileType(fileExtension: url.pathExtension)
    }

    private var seekOffset: Int

    private let url: URL
    private let fileManager: FileManager

    private var readSize: Int
    private var buffer: UnsafeMutablePointer<UInt8>
    private var inputStream: InputStream?

    init(url: URL,
         fileManager: FileManager = .default,
         underlyingQueue: DispatchQueue,
         readSize: Int = 64 * 1024)
    {
        self.url = url
        self.underlyingQueue = underlyingQueue
        self.fileManager = fileManager
        self.readSize = readSize
        buffer = UnsafeMutablePointer.uint8pointer(of: readSize)
        seekOffset = 0
        position = 0
        length = 0
    }

    deinit {
        buffer.deallocate()
    }

    func close() {
        guard let inputStream = inputStream else {
            return
        }
        CFReadStreamSetDispatchQueue(inputStream, nil)
        inputStream.close()
        inputStream.delegate = nil
    }

    // no-op
    func suspend() {}

    func resume() {
        guard let inputStream = inputStream else {
            return
        }
        CFReadStreamSetDispatchQueue(inputStream, underlyingQueue)
    }

    func seek(at offset: Int) {
        do {
            try performOpen(seek: offset)
        } catch {
            delegate?.errorOccurred(source: self, error: error)
        }
    }

    private func performOpen(seek seekOffset: Int) throws {
        close()
        try open()

        guard let inputStream = inputStream else {
            return
        }

        if inputStream.setProperty(seekOffset, forKey: .fileCurrentOffsetKey) {
            position = seekOffset
        } else {
            position = 0
        }
    }

    private func dataAvailable() {
        guard let inputStream = inputStream else { return }
        let read = inputStream.read(buffer, maxLength: readSize)
        if read > 0 {
            let data = Data(bytes: buffer, count: read)
            delegate?.dataAvailable(source: self, data: data)
            position += read
        } else {
            position += getCurrentOffsetFromStream()
        }
    }

    private func open() throws {
        guard let inputStream = InputStream(url: url) else {
            throw AudioSystemError.playerStartError
        }
        self.inputStream = inputStream
        CFReadStreamSetDispatchQueue(inputStream, underlyingQueue)
        inputStream.delegate = self
        inputStream.open()

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        length = (attributes[.size] as? Int) ?? 0
    }

    private func getCurrentOffsetFromStream() -> Int {
        guard let stream = inputStream else {
            return 0
        }
        return (stream.property(forKey: .fileCurrentOffsetKey) as? Int) ?? 0
    }
}

extension FileAudioSource: StreamDelegate {
    func stream(_: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            dataAvailable()
        case .endEncountered:
            delegate?.endOfFileOccurred(source: self)
        case .errorOccurred:
            delegate?.errorOccurred(source: self, error: AudioPlayerError.codecError)
        default:
            break
        }
    }
}
