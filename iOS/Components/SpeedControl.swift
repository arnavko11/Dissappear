import SwiftUI

struct SpeedControl: View {
    @Binding var speed: SimulationSpeed

    var body: some View {
        Menu {
            Picker("Simulation Speed", selection: $speed) {
                ForEach(SimulationSpeed.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(speed.title)
                .font(.callout.monospacedDigit())
                .frame(minWidth: 44)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .accessibilityLabel("Simulation speed")
        .accessibilityValue(speed.title)
    }
}
