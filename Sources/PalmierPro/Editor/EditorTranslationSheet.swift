import SwiftUI

struct EditorTranslationSheet: View {
    let request: EditorTranslationRequest
    @Environment(EditorViewModel.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var languageCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("Translate subtitles"))
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))

            Text(L10n.string("Enter a BCP-47 language code. The source subtitles remain on their own track."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            TextField(L10n.string("Language code, for example es-MX"), text: $languageCode)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Translate")) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.Workbench.translationSheetWidth)
        .onAppear {
            if languageCode.isEmpty {
                languageCode = Locale.current.language.languageCode?.identifier ?? ""
            }
        }
    }

    private func start() {
        let language = languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty else { return }
        editor.beginEditorTranslation(for: request.clipId, targetLanguageCode: language)
        dismiss()
    }
}
