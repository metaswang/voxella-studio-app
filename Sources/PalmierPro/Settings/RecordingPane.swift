import SwiftUI

struct RecordingPane: View {
    @State private var listenEnhanceEnabled: Bool = ListenEnhanceSettings.isEnabled

    var body: some View {
        SettingsToggleRow(
            title: "Enhance for listening",
            subtitle: "After recording stops, build a clearer listen track for playback and export. Transcription always uses the untouched master.",
            isOn: $listenEnhanceEnabled
        )
        .onAppear {
            listenEnhanceEnabled = ListenEnhanceSettings.isEnabled
        }
        .onChange(of: listenEnhanceEnabled) { _, newValue in
            ListenEnhanceSettings.isEnabled = newValue
        }
    }
}
