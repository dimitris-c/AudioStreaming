//
//  Created by Dimitrios Chatzieleftheriou.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct ContentView: View {

    @Environment(AppModel.self) var appModel

    @State private var selection: NavigationContent?

    var body: some View {
        NavigationStack {
            List {
                NavigationLink(value: NavigationContent.audioPlayer) {
                    Label("Audio Player", systemImage: "play")
                }

                NavigationLink(value: NavigationContent.audioQueue) {
                    Label("Audio Queue", systemImage: "play.square.stack")
                }
            }
            .navigationTitle("Home")
            .navigationDestination(for: NavigationContent.self) { content in
                DetailView(selection: content)
            }
        }
    }
}

#Preview {
    ContentView()
}
