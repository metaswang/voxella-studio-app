import SwiftUI

struct AudioPanelTab: View {
    var body: some View {
        SpeechTab()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }
}
