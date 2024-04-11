//
//  Created by Dimitrios Chatzieleftheriou.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

enum MainContent: Hashable {
    case audioPlayer
    case audioQueue
}

/// The navigation sidebar view.
///
/// The ``ContentView`` presents this view as the navigation sidebar view on macOS and iPadOS, and the root of the navigation stack on iOS.
/// The superview passes the person's selection in the ``Sidebar`` as the ``selection`` binding.
struct ContentSidebar: View {
    /// The person's selection in the sidebar.
    ///
    /// This value is a binding, and the superview must pass in its value.
    @Binding var selection: MainContent?

    /// The view body.
    ///
    /// The `Sidebar` view presents a `List` view, with a `NavigationLink` for each possible selection.
    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: MainContent.audioPlayer) {
                Label("Audio Player", systemImage: "play")
            }

            NavigationLink(value: MainContent.audioQueue) {
                Label("Audio Queue", systemImage: "play.square.stack")
            }
        }
        .navigationTitle("Home")
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 200, ideal: 200)
        #endif
    }
}

struct Sidebar_Previews: PreviewProvider {
    struct Preview: View {
        @State private var selection: MainContent? = MainContent.audioPlayer
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
