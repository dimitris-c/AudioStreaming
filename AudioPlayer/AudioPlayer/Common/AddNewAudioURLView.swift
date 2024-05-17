//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
//

import SwiftUI

struct AddNewAudioURLView: View {
    @Environment(\.dismiss) var dismiss

    private let urlStyle = URL.FormatStyle(path: .omitWhen(.path, matches: ["/"]), query: .omitWhen(.query, matches: [""]))

    @State private var audioUrl: URL?

    var onAddNewUrl: (URL) -> Void

    init(onAddNewUrl: @escaping (URL) -> Void) {
        self.onAddNewUrl = onAddNewUrl
    }

    var body: some View {
        NavigationStack {
            VStack {
                VStack(alignment: .leading) {
                    TextField(value: $audioUrl, format: urlStyle, prompt: nil, label: {
                        Text("Insert URL")
                    })
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        if let url = audioUrl {
                            onAddNewUrl(url)
                            dismiss()
                        }
                    }
                }
                .padding(.horizontal, 16)
                Button {
                    if let url = audioUrl {
                        onAddNewUrl(url)
                        dismiss()
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Add")
                    }
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(audioUrl == nil)
                .opacity(audioUrl == nil ? 0.5 : 1.0)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.mint)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .navigationTitle("Add Audio URL")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
#if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.gray)
                    }
                    .buttonStyle(.plain)
                }
#else
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
#endif
            }
        }
    }
}

#Preview {
    AddNewAudioURLView(onAddNewUrl: { _ in })
}
