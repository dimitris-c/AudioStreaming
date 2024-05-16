//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//


import SwiftUI

struct DetailView: View {
    @Environment(AppModel.self) var appModel

    var selection: NavigationContent

    var body: some View {
        switch selection {
        case .audioPlayer:
            AudioPlayerView(appModel: appModel)
        case .audioQueue: // TODO
            EmptyView()
        }
    }
}
