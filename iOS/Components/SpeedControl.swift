import SwiftUI

struct SpeedControl: View {
    @Binding var speed: SimulationSpeed

    var body: some View {
        Menu {
            Picker("Route Speed", selection: $speed) {
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
        .accessibilityLabel("Route speed")
        .accessibilityValue(speed.title)
    }
}
