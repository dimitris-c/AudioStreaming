 //
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct ContentView: View {

    @Environment(AppModel.self) var appModel
    @Environment(\.prefersStackNavigation) private var prefersStackNavigation

    @State private var selection: NavigationContent?

    var body: some View {
        if prefersStackNavigation {
            NavigationStack {
                ContentSidebar(selection: $selection)
                    .navigationTitle("Home")
            }
        } else {
            NavigationSplitView {
                ContentSidebar(selection: $selection)
                    .navigationTitle("Home")
            } detail: {
                if let selection {
                    DetailView(selection: selection)
                }
            }
            .onAppear {
                selection = .audioPlayer
            }
        }
    }
}
