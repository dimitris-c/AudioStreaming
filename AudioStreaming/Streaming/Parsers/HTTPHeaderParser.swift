//
//  Created by Dimitrios Chatzieleftheriou on 28/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import AudioToolbox.AudioFile
import Foundation

struct HeaderField {
    public static let acceptRanges = "Accept-Ranges"
    public static let contentLength = "Content-Length"
    public static let contentType = "Content-Type"
    public static let contentRange = "Content-Range"
}

enum IcyHeaderField {
    public static let icyMentaint = "icy-metaint"
}

struct HTTPHeaderParserOutput {
    let fileLength: Int
    let typeId: AudioFileTypeID
    // Metadata Support
    let metadataStep: Int
}

protocol HTTPHeaderParsing: Parser {
    /// Returns the value for the given field of the headers in the given `HTTPURLResponse`
    ///
    /// - Parameters:
    ///   - field: The header field to be searched
    ///   - response: The `HTTPURLResponse` for the header
    /// - Returns: A `String` if the field exists in the headers otherwise `nil`
    func value(forHTTPHeaderField field: String, in response: HTTPURLResponse) -> String?
}

struct HTTPHeaderParser: HTTPHeaderParsing {
    typealias Input = HTTPURLResponse
    typealias Output = HTTPHeaderParserOutput?

    func parse(input: HTTPURLResponse) -> HTTPHeaderParserOutput? {
        guard let headers = input.allHeaderFields as? [String: String], !headers.isEmpty else { return nil }

        var typeId: UInt32 = 0
        if let contentType = input.mimeType {
            typeId = audioFileType(mimeType: contentType)
        }

        var fileLength: Int = 0
        if input.statusCode == 200 {
            let contentLength = value(forHTTPHeaderField: HeaderField.contentLength, in: input)
            if let contentLength = contentLength, let length = Int(contentLength) {
                fileLength = length
            }
        } else if input.statusCode == 206 {
            if let contentLength = value(forHTTPHeaderField: HeaderField.contentRange, in: input) {
                let components = contentLength.components(separatedBy: "/")
                if components.count == 2 {
                    if let last = components.last, let length = Int(last) {
                        fileLength = length
                    }
                }
            }
        }

        var metadataStep = 0
        if let icyMetaint = value(forHTTPHeaderField: IcyHeaderField.icyMentaint, in: input),
           let intValue = Int(icyMetaint)
        {
            metadataStep = intValue
        }

        return HTTPHeaderParserOutput(fileLength: fileLength,
                                      typeId: typeId,
                                      metadataStep: metadataStep)
    }
}

extension Parser where Self: HTTPHeaderParsing {
    func value(forHTTPHeaderField field: String, in response: HTTPURLResponse) -> String? {
        if #available(iOS 13.0, *) {
            return response.value(forHTTPHeaderField: field)
        } else {
            if let fields = response.allHeaderFields as? [String: String] {
                return valueForCaseInsensitiveKey(field, fields: fields)
            } else {
                return nil
            }
        }
    }

    private func valueForCaseInsensitiveKey(_ key: String, fields: [String: String]) -> String? {
        let keyToBeFound = key.lowercased()
        for (key, value) in fields {
            if key.lowercased() == keyToBeFound {
                return value
            }
        }
        return nil
    }
}
