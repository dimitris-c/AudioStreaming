//
//  Created by Dimitris Chatzieleftheriou on 15/04/2024.
//

import SwiftUI

@Observable
class EQBand: Identifiable {
    var frequency: String
    var min: Float
    var max: Float
    var value: Float

    @ObservationIgnored
    let index: Int

    init(index: Int, frequency: String, min: Float, max: Float, value: Float) {
        self.index = index
        self.frequency = frequency
        self.min = min
        self.max = max
        self.value = value
    }
}

struct EqualizerView: View {
    @Environment(\.dismiss) var dismiss

    @Environment(AppModel.self) var appModel

    @State var model: Model

    init(appModel: AppModel) {
        self._model = State(wrappedValue: Model(equalizerService: appModel.equalizerService))
    }

    var body: some View {
        NavigationStack {
            VStack {
                Toggle(isOn: $model.isEnabled) {
                    Text("Enable")
                }
                .onChange(of: model.isEnabled) { _, _ in
                    model.enable()
                }
                .padding(.horizontal, 16)
                VStack {
                    EQSliderView()
                        .frame(height: 180)
                        .padding(.horizontal, 16)
                        .environment(model)
                    Button {
                        withAnimation {
                            model.reset()
                        }
                    } label: {
                        HStack {
                            Text("Reset")
                        }
                        .foregroundStyle(Color.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .task {
                Task {
                    model.generateBands()
                }
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.gray)
                    }
                }
            }
        }
    }
}

struct EQSliderView: View {
    @Environment(EqualizerView.Model.self) var eqModel

    @State private var dragPointYLocations: [CGFloat] = Array(repeating: .zero, count: 6)

    @State private var eqViewFrame: CGRect = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Draw labels for gain values
                VStack {
                    Text("\(Int(eqModel.maxGain))db")
                        .font(.caption2)
                        .foregroundColor(.black)
                    Spacer()
                    Text("0dB")
                        .font(.caption2)
                        .foregroundColor(.black)
                    Spacer()
                    Text("\(Int(eqModel.minGain))db")
                        .font(.caption2)
                        .foregroundColor(.black)
                }
                GeometryReader { innerGeo in
                    ZStack {
                        Path { path in
                            path.move(to: CGPoint(x: innerGeo.size.width / 12, y: eqModel.dragPoints.first ?? 0))
                            for index in 1..<eqModel.dragPoints.count {
                                let x = positionForDragPoint(at: index, size: innerGeo.size)
                                let y =  eqModel.dragPoints[index]
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                        .stroke(Color.mint, lineWidth: 2)
                        .animation(.default, value: eqModel.dragPoints)

                        Path { path in
                            for index in 0..<eqModel.dragPoints.count {
                                let x = positionForDragPoint(at: index, size: innerGeo.size)
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: innerGeo.size.height))
                            }
                            path.move(to: CGPoint(x: 0, y: innerGeo.size.height / 2))
                            path.addLine(to: CGPoint(x: innerGeo.size.width, y: innerGeo.size.height / 2))
                        }
                        .stroke(Color.gray, lineWidth: 1)

                        ForEach(eqModel.bands) { band in
                            Circle()
                                .fill(Color.mint)
                                .frame(width: 20, height: 20)
                                .position(x: positionForDragPoint(at: band.index, size: innerGeo.size), y: eqModel.dragPoints[band.index])
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let newY = min(max(value.location.y, 0), innerGeo.size.height)
                                            eqModel.dragPoints[band.index] = newY
                                            updateGainValue(at: band.index, in: innerGeo.size)
                                        }
                                )
                                .onAppear {
                                    eqModel.dragPoints[band.index] = gainToYPosition(at: band.value, in: innerGeo.size)
                                }
                        }
                    }

                    ForEach(eqModel.bands) { band in
                        Text(band.frequency)
                            .position(x: positionForDragPoint(at: band.index, size: innerGeo.size), y: innerGeo.size.height)
                            .font(.caption)
                            .foregroundColor(.black)

                    }
                }
            }
        }
    }

    func positionForDragPoint(at index: Int, size: CGSize) -> CGFloat {
        size.width / 12 * CGFloat(index * 2 + 1)
    }

    func updateGainValue(at index: Int, in size: CGSize) {
        let percentage = dragPointYLocations[index] / size.height
        let gain = (1 - Float(percentage)) * (eqModel.maxGain - eqModel.minGain) + eqModel.minGain
        eqModel.update(gain: gain, index: index)
    }

    func gainToYPosition(at gain: Float, in size: CGSize) -> CGFloat {
        let percentage = 1 - (gain - eqModel.minGain) / (eqModel.maxGain - eqModel.minGain)
        return CGFloat(percentage) * size.height
    }
}

extension EqualizerView {
    @Observable
    class Model {
        @ObservationIgnored
        private let equalizerService: EqualizerService

        var isEnabled: Bool = false

        var bands: [EQBand] = []

        var dragPoints: [CGFloat] = []

        let minGain: Float = -12
        let maxGain: Float = 12

        init(equalizerService: EqualizerService) {
            self.equalizerService = equalizerService
            dragPoints = [CGFloat].init(repeating: 0, count: equalizerService.bands.count)
        }

        func generateBands() {
            bands = equalizerService.bands.enumerated().map { index, item in
                var measurement = item.frequency
                var frequency = String(Int(measurement))
                if item.frequency >= 1000 {
                    measurement = item.frequency / 1000
                    frequency = "\(String(Int(measurement)))K"
                }
                return EQBand(index: index, frequency: frequency, min: minGain, max: maxGain, value: item.gain)
            }

            dragPoints = [CGFloat].init(repeating: 0, count: bands.count)
        }

        func enable() {
            if isEnabled {
                equalizerService.activate()
            } else {
                equalizerService.deactivate()
            }
        }

        func update(gain: Float, index: Int) {
            equalizerService.update(gain: gain, for: index)
        }

        func reset() {
            equalizerService.reset()
            dragPoints = [CGFloat].init(repeating: 0, count: bands.count)
        }
    }
}

#Preview {
    EqualizerView(appModel: AppModel())
}
