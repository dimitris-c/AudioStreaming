//
//  Created by Dimitrios Chatzieleftheriou.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct ContentView: View {
    
    @State private var selection: MainContent?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView {
            ContentSidebar(selection: $selection)
        } detail: {
            DetailView(selection: $selection)
        }
    }
}

#Preview {
    ContentView()
}
