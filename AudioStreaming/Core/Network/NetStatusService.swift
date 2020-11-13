//
//  Created by Dimitrios Chatzieleftheriou on 18/09/2020.
//  Copyright © 2020 decimal. All rights reserved.
//

import Foundation
import Network

enum NetConnectionType: Equatable {
    case cellular(connected: Bool)
    case wifi(connected: Bool)
    case undetermined

    var isConnected: Bool {
        switch self {
        case let .cellular(connected),
             let .wifi(connected):
            return connected
        default:
            return false
        }
    }
}

protocol NetStatusProvider {
    var isConnected: Bool { get }
    var connectionType: NetConnectionType { get }

    func start(connectionChange: @escaping (NetConnectionType) -> Void)
    func stop()
}

final class NetStatusService: NetStatusProvider {
    var isConnected: Bool {
        network.currentPath.status == .satisfied
    }

    var connectionType: NetConnectionType {
        network.currentPath.toNetConnectionType()
    }

    private var currentConnectionType: NetConnectionType = .undetermined

    private let network: NWPathMonitor

    private let monitorQueue: DispatchQueue

    init(network: NWPathMonitor) {
        self.network = network
        monitorQueue = DispatchQueue(label: "net.path.queue", qos: .background)
    }

    deinit {
        network.cancel()
    }

    /// Starts the monitoring of connection changes
    ///
    /// - parameter connectionChange: A callback block to listen to changes of the network type, this skips duplicates.
    /// - Note:  The callback will be executed on the main thread.
    func start(connectionChange: @escaping (NetConnectionType) -> Void) {
        network.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connecionType = path.toNetConnectionType()
            if self.currentConnectionType != connecionType {
                connectionChange(self.connectionType)
                self.currentConnectionType = self.connectionType
            }
        }
        startIfNeeded()
    }

    func stop() {
        network.cancel()
        network.pathUpdateHandler = nil
    }

    func startIfNeeded() {
        guard network.queue == nil else { return }
        network.start(queue: monitorQueue)
    }
}

extension NWPath {
    func toNetConnectionType() -> NetConnectionType {
        let isCellular = usesInterfaceType(.cellular)
        let isWifi = usesInterfaceType(.wifi)
        let isConnected = status == .satisfied

        if isCellular {
            return .cellular(connected: isConnected)
        } else if isWifi {
            return .wifi(connected: isConnected)
        }

        return .undetermined
    }
}
