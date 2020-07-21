//
//  Created by Dimitrios Chatzieleftheriou on 26/05/2020.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation

/// A convenient type that holds tasks in a two-way manner, such as `URLSessionTask` to `NetworkDataStream` and reverved
struct NetworkTasksMap {
    
    private var tasks: [URLSessionTask: NetworkDataStream] = [:]
    private var streams: [NetworkDataStream: URLSessionTask] = [:]
    
    var requests: [NetworkDataStream] {
        Array(tasks.values)
    }
    
    subscript(_ task: URLSessionTask) -> NetworkDataStream? {
        get { tasks[task] }
        set {
            guard let newValue = newValue else {
                guard let stream = tasks[task] else {
                    fatalError("incosistency error: no task to request found")
                }
                tasks.removeValue(forKey: task)
                streams.removeValue(forKey: stream)
                return
            }
            
            tasks[task] = newValue
            streams[newValue] = task
        }
    }
    
    subscript(_ stream: NetworkDataStream) -> URLSessionTask? {
        get { streams[stream] }
        set {
            guard let newValue = newValue else {
                guard let request = streams[stream] else {
                    fatalError("incosistency error: no task to request found")
                }
                print("Removing stream: \(request.currentRequest)")
                tasks.removeValue(forKey: request)
                streams.removeValue(forKey: stream)
                return
            }
            
            streams[stream] = newValue
            tasks[newValue] = stream
        }
    }
    
}
