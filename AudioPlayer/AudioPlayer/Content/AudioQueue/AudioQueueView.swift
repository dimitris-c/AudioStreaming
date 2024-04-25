//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct AudioQueueView: View {
    @Environment(AppModel.self) var appModel

    @State var model: AudioPlayerModel

    @State var eqSheetIsShown: Bool = false
    @State var addNewAudioIsShown: Bool = false

    init(appModel: AppModel) {
        self._model = State(wrappedValue: AudioPlayerModel(audioPlayerService: appModel.audioPlayerService))
    }
    
    var body: some View {
        return Text("")
    }
}

#Preview {
    AudioQueueView(appModel: AppModel())
}
