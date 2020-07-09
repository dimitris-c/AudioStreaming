//
//  Created by Dimitrios Chatzieleftheriou on 28/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import AudioToolbox.AudioFile

struct HeaderField {
    public static let acceptRanges = "Accept-Ranges"
    public static let contentLength = "Content-Length"
    public static let contentType = "Content-Type"
    public static let contentRange = "Content-Range"
}

struct IcyHeaderField {
    public static let icyMentaint = "icy-metaint"
}

struct HTTPHeaderParserOutput {
    let supportsSeek: Bool
    let fileLength: Int
    let typeId: AudioFileTypeID
    // Metadata Support
    let metadataStep: Int
}

struct HTTPHeaderParser: Parser {
    typealias Input = HTTPURLResponse
    typealias Output = HTTPHeaderParserOutput?
    
    func parse(input: HTTPURLResponse) -> HTTPHeaderParserOutput? {
        
        guard let headers = input.allHeaderFields as? [String: String], !headers.isEmpty else { return nil }

        var supportsSeek = false
        if let acceptRanges = headers[HeaderField.acceptRanges], acceptRanges != "none" {
            supportsSeek = true
        }
        
        var typeId: UInt32 = 0
        if let contentType = input.mimeType {
            typeId = audioFileType(mimeType: contentType)
        }
        
        var fileLength: Int = 0
        if input.statusCode == 200 {
            if let contentLength = headers[HeaderField.contentLength],
                let length = Int(contentLength) {
                fileLength = length
            }
        } else if input.statusCode == 206 {
            if let contentLength = headers[HeaderField.contentRange] {
                let components = contentLength.components(separatedBy: "/")
                if components.count == 2 {
                    if let last = components.last, let length = Int(last) {
                        fileLength = length
                    }
                }
            }
        }
        
        var metadataStep = 0
        if let icyMetaint = headers[IcyHeaderField.icyMentaint],
            let intValue = Int(icyMetaint)  {
            metadataStep = intValue
        }
        
        return HTTPHeaderParserOutput(supportsSeek: supportsSeek,
                                      fileLength: fileLength,
                                      typeId: typeId,
                                      metadataStep: metadataStep)
        
    }
    
}

struct CFHTTPResponseParser: Parser {
    typealias Input = CFHTTPMessage
    typealias Output = HTTPHeaderParserOutput
    func parse(input: CFHTTPMessage) -> HTTPHeaderParserOutput {
        let headers = CFHTTPMessageCopyAllHeaderFields(input)?.takeRetainedValue() as? [String: Any]
        let statusCode = CFHTTPMessageGetResponseStatusCode(input)
        var supportsSeek = false
        if let acceptRanges = headers?[HeaderField.acceptRanges] as? String, acceptRanges != "none" {
            supportsSeek = true
        }
        
        var typeId: UInt32 = 0
        if let contentType = headers?["Content-Type"] as? String {
            typeId = audioFileType(mimeType: contentType)
        }
        
        var fileLength: Int = 0
        if statusCode == 200 {
            if let contentLength = headers?[HeaderField.contentLength] as? String,
                let length = Int(contentLength) {
                fileLength = length
            }
        } else if statusCode == 206 {
            if let contentLength = headers?[HeaderField.contentRange] as? String {
                let components = contentLength.components(separatedBy: "/")
                if components.count == 2 {
                    if let last = components.last, let length = Int(last) {
                        fileLength = length
                    }
                }
            }
        }
        
        var metadataStep = 0
        if let icyMetaint = headers?[IcyHeaderField.icyMentaint] as? String,
            let intValue = Int(icyMetaint)  {
            metadataStep = intValue
        }
        
        return HTTPHeaderParserOutput(supportsSeek: supportsSeek,
                                      fileLength: fileLength,
                                      typeId: typeId,
                                      metadataStep: metadataStep)
    }
    
}
