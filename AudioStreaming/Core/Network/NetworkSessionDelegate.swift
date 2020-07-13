//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

internal final class NetworkSessionDelegate: NSObject, URLSessionDataDelegate {
    
    weak var taskProvider: StreamTaskProvider?
    
    internal func stream(for task: URLSessionTask) -> NetworkDataStream? {
        guard let taskProvider = taskProvider else {
            assertionFailure("couldn't found taskProvider")
            return nil
        }
        return taskProvider.dataStream(for: task)
    }
    
    internal func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if let stream = self.stream(for: dataTask) {
            stream.didReceive(data: data, response: dataTask.response as? HTTPURLResponse)
        } else {
            assertionFailure("couldn't found related stream task in didReceiveData")
        }
    }

    internal func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let stream = self.stream(for: task) {
            stream.didComplete(with: error)
        }
    }
    
}

//extension NetworkSessionDelegate: URLSessionTaskDelegate {
//    
//    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
//        completionHandler(.performDefaultHandling, nil)
//    }
//    
//}
