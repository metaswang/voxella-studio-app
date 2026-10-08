import SwiftUI

struct SessionPlaybackPane: View {
    @State private var autoPlayEnabled: Bool = SessionAutoPlaySettings.isEnabled

    var body: some View {
        SettingsToggleRow(
            title: "Auto-play sessions",
            subtitle: "Start playback as soon as a session opens.",
            isOn: $autoPlayEnabled
        )
        .onChange(of: autoPlayEnabled) { _, newValue in
            SessionAutoPlaySettings.isEnabled = newValue
        }
    }
}
