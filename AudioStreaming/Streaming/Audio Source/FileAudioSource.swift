//
//  Created by Dimitrios Chatzieleftheriou on 11/11/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import AVFoundation

final class FileAudioSource: NSObject, CoreAudioStreamSource {
    weak var delegate: AudioStreamSourceDelegate?

    var underlyingQueue: DispatchQueue

    var position: Int
    var length: Int

    var audioFileHint: AudioFileTypeID {
        audioFileType(fileExtension: url.pathExtension)
    }

    private var isMp4: Bool {
        audioFileHint == kAudioFileM4AType || audioFileHint == kAudioFileMPEG4Type
    }

    private var mp4IsAlreadyOptimized: Bool = false

    private var seekOffset: Int

    private let url: URL
    private let fileManager: FileManager

    private var readSize: Int
    private var buffer: UnsafeMutablePointer<UInt8>
    private var inputStream: InputStream?

    private var mp4Restructure: Mp4Restructure

    init(url: URL,
         fileManager: FileManager = .default,
         underlyingQueue: DispatchQueue,
         readSize: Int = 64 * 1024)
    {
        self.url = url
        self.underlyingQueue = underlyingQueue
        self.fileManager = fileManager
        self.readSize = readSize
        self.mp4Restructure = Mp4Restructure()
        buffer = UnsafeMutablePointer.uint8pointer(of: readSize)
        seekOffset = 0
        position = 0
        length = 0
    }

    deinit {
        buffer.deallocate()
        mp4Restructure.clear()
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
        var reopened = false
        let status = inputStream?.streamStatus ?? .closed
        if status == .atEnd || status == .closed || status == .error {
            reopened = true
            close()
            try open()
        }

        var offset = seekOffset
        if isMp4, mp4Restructure.dataOptimized {
            offset = mp4Restructure.seekAdjusted(offset: seekOffset)
        }

        if inputStream?.setProperty(offset, forKey: .fileCurrentOffsetKey) == true {
            position = offset
        } else {
            position = 0
        }

        if !reopened {
            underlyingQueue.async { [weak self] in
                if self?.inputStream?.hasBytesAvailable == true {
                    self?.dataAvailable()
                }
            }
        }
    }

    private func dataAvailable() {
        guard let inputStream = inputStream else { return }
        let read = inputStream.read(buffer, maxLength: readSize)
        if read > 0 {
            let data = Data(bytes: buffer, count: read)
            if isMp4, !mp4IsAlreadyOptimized {
                if !mp4Restructure.dataOptimized {
                    do {
                        if let mp4OptimizeInfo = try mp4Restructure.checkIsOptimized(data: data) {
                            try performMp4Restructure(inputStream: inputStream, mp4OptimizeInfo: mp4OptimizeInfo)
                        } else {
                            mp4IsAlreadyOptimized = true
                            delegate?.dataAvailable(source: self, data: data)
                        }
                    } catch {
                        delegate?.errorOccurred(source: self, error: error)
                    }
                } else {
                    delegate?.dataAvailable(source: self, data: data)
                }
            } else {
                delegate?.dataAvailable(source: self, data: data)
            }
            position += read
        } else {
            position += getCurrentOffsetFromStream()
        }
    }

    func performMp4Restructure(inputStream: InputStream, mp4OptimizeInfo: Mp4OptimizeInfo) throws {
        let offsetAccepted = inputStream.setProperty(mp4OptimizeInfo.moovOffset, forKey: .fileCurrentOffsetKey)
        if offsetAccepted {
            let moovDataBuffer = UnsafeMutablePointer.uint8pointer(of: mp4OptimizeInfo.moovSize)
            defer { moovDataBuffer.deallocate() }
            let moovRead = inputStream.read(moovDataBuffer, maxLength: mp4OptimizeInfo.moovSize)
            if moovRead > 0 {
                let data = Data(bytes: moovDataBuffer, count: moovRead)
                let moovData = try mp4Restructure.restructureMoov(data: data)
                delegate?.dataAvailable(source: self, data: moovData.initialData)
                if !inputStream.setProperty(moovData.mdatOffset, forKey: .fileCurrentOffsetKey) {
                    delegate?.errorOccurred(source: self, error: AudioSystemError.playerStartError)
                }
            } else {
                delegate?.errorOccurred(source: self, error: AudioSystemError.playerStartError)
            }
        } else {
            delegate?.errorOccurred(source: self, error: inputStream.streamError ?? AudioSystemError.playerStartError)
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
