import SwiftUI

/// Settings → Models shows on-device speech models used by Workbench.
struct ModelsPane: View {
    var body: some View {
        LocalModelManagerView(presentation: .settings)
    }
}
