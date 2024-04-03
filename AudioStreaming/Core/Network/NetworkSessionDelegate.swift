//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

final class NetworkSessionDelegate: NSObject, URLSessionDataDelegate {
    weak var taskProvider: StreamTaskProvider?

    func stream(for task: URLSessionTask) -> NetworkDataStream? {
        guard let taskProvider = taskProvider else {
            assertionFailure("couldn't found taskProvider")
            return nil
        }
        return taskProvider.dataStream(for: task)
    }

    func urlSession(_: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data)
    {
        guard let stream = stream(for: dataTask) else {
            return
        }
        stream.didReceive(data: data,
                          response: dataTask.response as? HTTPURLResponse)
    }

    func urlSession(_: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?)
    {
        guard let stream = stream(for: task) else {
            return
        }
        stream.didComplete(with: error, response: task.response as? HTTPURLResponse)
    }

    func urlSession(_: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    {
        guard let stream = stream(for: dataTask) else {
            return
        }
        stream.didReceive(response: response as? HTTPURLResponse)
        completionHandler(.allow)
    }
}
