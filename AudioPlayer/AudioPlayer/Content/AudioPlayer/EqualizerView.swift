//
//  Created by Dimitris C.
//  Copyright © 2024 Decimal. All rights reserved.
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
            VStack(spacing: 16) {
                EQSliderView()
                    .frame(height: 180)
                    .padding(.horizontal, 16)
                    .environment(model)

                HStack(alignment: .center, spacing: 16) {
                    Button {
                        withAnimation {
                            model.isEnabled.toggle()
                            model.enable()
                        }
                    } label: {
                        HStack {
                            Image(systemName: model.isEnabled ? "waveform.slash" : "waveform")
                                .contentTransition(.symbolEffect(.replace))
                            Text(model.isEnabled ? "Disable": "Enable")
                                .font(.body)
                        }
                        .foregroundStyle(Color.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(model.isEnabled ? .red : .mint)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button {
                        model.reset()
                    } label: {
                        HStack {
                            Text("Reset")
                                .font(.body)
                        }
                        .foregroundStyle(Color.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(.mint)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.top, 24)
            }
            .task {
                Task {
                    model.generateBands()
                }
            }
            .navigationTitle("Equalizer")
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

struct EQSliderView: View {
    @Environment(EqualizerView.Model.self) var eqModel

    @State private var dragPointYLocations: [CGFloat] = Array(repeating: .zero, count: 6)
    @State private var resetPoints: [Double] = Array(repeating: .zero, count: 6)

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
                        LineShape(values: eqModel.shouldReset ? resetPoints : dragPointYLocations.map { Double($0) })
                            .stroke(Color.mint, lineWidth: 2)
                            .animation(.easeInOut(duration: 0.2), value: eqModel.shouldReset)
                            .onAppear {
                                resetPoints = resetPoints.map { _ in Double(gainToYPosition(at: 0, in: innerGeo.size)) }
                            }

                        Path { path in
                            for index in 0..<dragPointYLocations.count {
                                let x = positionForDragPoint(at: index, size: innerGeo.size)
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: innerGeo.size.height))
                            }
                            path.move(to: CGPoint(x: 0, y: innerGeo.size.height / 2))
                            path.addLine(to: CGPoint(x: innerGeo.size.width, y: innerGeo.size.height / 2))
                        }
                        .stroke(Color.gray.opacity(0.5), lineWidth: 1)

                        ForEach(eqModel.bands) { band in
                            Circle()
                                .fill(Color.mint)
                                .frame(width: 20, height: 20)
                                .position(x: positionForDragPoint(at: band.index, size: innerGeo.size), y: dragPointYLocations[band.index])
                                .gesture(
                                    DragGesture()
                                        .onChanged { value in
                                            let newY = min(max(value.location.y, 0), innerGeo.size.height)
                                            dragPointYLocations[band.index] = newY
                                            updateGainValue(at: band.index, in: innerGeo.size)
                                        }
                                )
                                .onAppear {
                                    dragPointYLocations[band.index] = gainToYPosition(at: band.value, in: innerGeo.size)
                                }
                                .onChange(of: eqModel.shouldReset) { _, reset in
                                    if reset {
                                        resetPositions(in: innerGeo.size)
                                    }
                                }
                        }
                    }

                    ForEach(eqModel.bands) { band in
                        Text(band.frequency)
                            .position(x: positionForDragPoint(at: band.index, size: innerGeo.size), y: innerGeo.size.height + 8)
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

    func resetPositions(in size: CGSize) {
        let reset = dragPointYLocations.map { _ in gainToYPosition(at: 0, in: size) }
        withAnimation(.easeInOut(duration: 0.2)) {
            dragPointYLocations = reset
        }

    }
}

extension EqualizerView {
    @Observable
    class Model {
        @ObservationIgnored
        private let equalizerService: EqualizerService

        var dragPointYLocations: [CGFloat] = Array(repeating: .zero, count: 6)

        var isEnabled: Bool = false

        var bands: [EQBand] = []

        let minGain: Float = -12
        let maxGain: Float = 12

        var shouldReset: Bool = false

        init(equalizerService: EqualizerService) {
            self.equalizerService = equalizerService
            isEnabled = equalizerService.isActivated
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
        }

        func enable() {
            if isEnabled {
                equalizerService.activate()
            } else {
                equalizerService.deactivate()
            }
        }

        func update(gain: Float, index: Int) {
            shouldReset = false
            bands[index].value = gain
            equalizerService.update(gain: gain, for: index)
        }

        func reset() {
            guard !shouldReset else {
                return
            }
            shouldReset = true
            equalizerService.reset()
            for band in bands {
                band.value = 0.0
            }
        }
    }
}

struct LineShape: Shape {
    var values: [Double]

    var animatableData: AnimatableLine {
        get { AnimatableLine(values: values) }
        set { values = newValue.values }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.size.width / 12, y: values.first ?? 0))
        for index in 1..<values.count {
            let x = positionForDragPoint(at: index, size: rect.size)
            let y =  values[index]
            path.addLine(to: CGPoint(x: x, y: y))
        }
        return path
    }

    func positionForDragPoint(at index: Int, size: CGSize) -> CGFloat {
        size.width / 12 * CGFloat(index * 2 + 1)
    }
}

struct AnimatableLine : VectorArithmetic {
    var values: [Double]

    var magnitudeSquared: Double {
        return values.map { $0 * $0 }.reduce(0, +)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    static var zero: AnimatableLine {
        return AnimatableLine(values: [0.0])
    }

    static func - (lhs: AnimatableLine, rhs: AnimatableLine) -> AnimatableLine {
        return AnimatableLine(values: zip(lhs.values, rhs.values).map(-))
    }

    static func -= (lhs: inout AnimatableLine, rhs: AnimatableLine) {
        lhs = lhs - rhs
    }

    static func + (lhs: AnimatableLine, rhs: AnimatableLine) -> AnimatableLine {
        return AnimatableLine(values: zip(lhs.values, rhs.values).map(+))
    }

    static func += (lhs: inout AnimatableLine, rhs: AnimatableLine) {
        lhs = lhs + rhs
    }
}

#Preview {
    EqualizerView(appModel: AppModel())
}
