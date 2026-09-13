import SwiftUI

struct SpeakerIdentificationPreparationRow: View {
    @Bindable private var manager = LocalModelManager.shared
    @State private var showsTerms = false

    private var id: LocalModelID { .sortformerDiarization }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Label(L10n.string("Speaker identification"), systemImage: "person.2.wave.2")
                    .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                Spacer()
                switch manager.state(for: id) {
                case .installed:
                    Label(L10n.string("Ready"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Status.successColor)
                case .queued, .downloading:
                    Button(L10n.string("Cancel download")) { manager.cancel(id) }
                case .notInstalled, .failed:
                    Button(L10n.string("Download")) {
                        if manager.isLicenseAccepted(id) { manager.download(id) }
                        else { showsTerms = true }
                    }
                }
            }
            Text(L10n.string("Optional: distinguish speakers in a conversation. Additional terms apply."))
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            if case .failed = manager.state(for: id) {
                Text(L10n.string("Download could not finish. Check your connection and available disk space, then retry."))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
            if showsTerms {
                Text(L10n.string("Review the additional terms before downloading this feature."))
                if let url = manager.descriptor(for: id).licenseURL {
                    Link(L10n.string("Read terms"), destination: url)
                }
                HStack {
                    Button(L10n.string("Cancel")) { showsTerms = false }
                    Button(L10n.string("Accept and download")) {
                        manager.acceptLicense(id)
                        manager.download(id)
                        showsTerms = false
                    }
                }
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Background.surfaceColor, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }
}
