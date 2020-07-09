//
//  Created by Dimitrios Chatzieleftheriou on 28/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

public enum MetadataParsingError: Error, Equatable {
    case unableToParse
    case empty
}

typealias MetadataOutput = Result<[String: String], MetadataParsingError>

struct MetadataParser: Parser {
    typealias Input = Data?
    typealias Output = MetadataOutput
    
    private let zeroBytesCharSet = CharacterSet(charactersIn: "\0")
    func parse(input: Data?) -> MetadataOutput {
        guard let data = input else { return .failure(.unableToParse) }
        
        guard let string = String(data: data, encoding: .utf8) else { return .failure(.unableToParse) }
        // remove added bytes (zeros) and seperate the string on every ';' char
        let pairs = string.trimmingCharacters(in: zeroBytesCharSet).components(separatedBy: ";")
        let temp: [String: String] = [:]
        let metadata = pairs.reduce(into: temp) { (result, next) in
            let paired = next.components(separatedBy: "=")
            if let key = paired.first,
                let value = paired.last?.replacingOccurrences(of: "'", with: ""), !key.isEmpty {
                result[key] = value
            }
        }
        guard !metadata.isEmpty else { return .failure(.empty)}
        return .success(metadata)
    }
}
