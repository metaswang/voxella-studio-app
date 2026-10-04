import SwiftUI

enum LibraryLayout: String, Hashable {
    case grid
    case list
}

struct LibraryLayoutPicker: View {
    @Binding var layout: LibraryLayout
    let accessibilityLabel: String

    var body: some View {
        Picker(L10n.string("Layout"), selection: $layout) {
            Image(systemName: "square.grid.2x2")
                .tag(LibraryLayout.grid)
                .accessibilityLabel(L10n.string("Grid"))
                .help(L10n.string("Grid"))
            Image(systemName: "list.bullet")
                .tag(LibraryLayout.list)
                .accessibilityLabel(L10n.string("List"))
                .help(L10n.string("List"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: AppTheme.VideoEditorHome.layoutPickerWidth)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}
