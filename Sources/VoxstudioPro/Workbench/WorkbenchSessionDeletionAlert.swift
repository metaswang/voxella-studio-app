import SwiftUI

struct RecentSessionDeletionRequest: Identifiable {
    let id = UUID()
    let sessions: [WorkbenchSession]

    @MainActor static func prepare(
        sessions: [WorkbenchSession],
        store: WorkbenchStore = .shared
    ) -> Self? {
        guard !sessions.isEmpty else { return nil }
        let cloudSessions = sessions.filter { $0.storage == .cloud || $0.remoteSessionID != nil }
        for session in cloudSessions {
            store.deleteSession(session.id)
        }
        let localSessions = sessions.filter { $0.storage != .cloud && $0.remoteSessionID == nil }
        return localSessions.isEmpty ? nil : Self(sessions: localSessions)
    }

    @MainActor var title: String {
        sessions.count == 1
            ? L10n.string("Delete session?")
            : L10n.format("Delete %@ sessions?", sessions.count)
    }

    @MainActor var message: String {
        return sessions.count == 1
            ? L10n.format("\"%@\" and its saved workflow data will be removed.", sessions[0].title)
            : L10n.format("The %@ selected sessions and their saved workflow data will be removed.", sessions.count)
    }

    @MainActor var deleteButtonTitle: String {
        return sessions.count == 1 ? L10n.string("Delete") : L10n.format("Delete %@", sessions.count)
    }
}

extension View {
    func sessionDeletionAlert(
        item: Binding<RecentSessionDeletionRequest?>,
        onFinished: @escaping () -> Void = {}
    ) -> some View {
        alert(
            item.wrappedValue?.title ?? L10n.string("Delete session?"),
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            presenting: item.wrappedValue
        ) { request in
            Button(request.deleteButtonTitle, role: .destructive) {
                // Use the confirmed snapshot, not a selection changed while the alert is open.
                for session in request.sessions {
                    WorkbenchStore.shared.deleteSession(session.id)
                }
                onFinished()
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { request in
            Text(request.message)
        }
    }
}
