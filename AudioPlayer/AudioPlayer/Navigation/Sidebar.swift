//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

enum NavigationContent: Hashable {
    case audioPlayer
    case audioQueue
}

struct ContentSidebar: View {
    @Binding var selection: NavigationContent?

    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: NavigationContent.audioPlayer) {
                Label("Audio Player", systemImage: "play")
            }

            NavigationLink(value: NavigationContent.audioQueue) {
                Label("Audio Queue", systemImage: "play.square.stack")
            }
        }
        .navigationTitle("Home")
        .navigationDestination(item: $selection, destination: { selection in
            DetailView(selection: selection)
        })
    }
}

struct Sidebar_Previews: PreviewProvider {
    struct Preview: View {
        @State private var selection: NavigationContent? = NavigationContent.audioPlayer
        var body: some View {
            ContentSidebar(selection: $selection)
        }
    }

    static var previews: some View {
        NavigationSplitView {
            Preview()
        } detail: {
           Text("Detail!")
        }
    }
}
