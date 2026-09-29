import Foundation
import Testing
@testable import PalmierPro

@Suite("Workbench navigation history")
@MainActor
struct WorkbenchNavigatorTests {
    @Test func pendingNavigationIsCommittedBeforeBack() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        await workspace.visit(.place(.recent), navigator: navigator)
        workspace.screen = .session(UUID())
        navigator.note(workspace.screen)
        let session = workspace.screen

        navigator.goBack()
        #expect(workspace.screen == .place(.recent))
        #expect(navigator.canGoForward)
        navigator.goForward()
        #expect(workspace.screen == session)
    }

    @Test func backCapturesChangesBeforeSwiftUIReportsThem() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        await workspace.visit(.place(.recent), navigator: navigator)
        workspace.screen = .place(.knowledge)

        navigator.goBack()
        #expect(workspace.screen == .place(.recent))
        navigator.goForward()
        #expect(workspace.screen == .place(.knowledge))
    }

    @Test func rapidBackAndForwardKeepEveryStep() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        let session = WorkbenchScreen.session(UUID())
        await workspace.visit(.place(.recent), navigator: navigator)
        await workspace.visit(.place(.knowledge), navigator: navigator)
        await workspace.visit(session, navigator: navigator)

        navigator.goBack()
        navigator.goBack()
        #expect(workspace.screen == .place(.recent))
        #expect(!navigator.canGoBack)
        navigator.goForward()
        #expect(workspace.screen == .place(.knowledge))
        navigator.goForward()
        #expect(workspace.screen == session)
        #expect(!navigator.canGoForward)
    }

    @Test func directNavigationAfterBackCreatesANewBranch() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        await workspace.visit(.place(.recent), navigator: navigator)
        await workspace.visit(.place(.knowledge), navigator: navigator)
        await workspace.visit(.session(UUID()), navigator: navigator)

        navigator.goBack()
        workspace.screen = .place(.dashboard)
        navigator.note(workspace.screen)
        navigator.goBack()
        #expect(workspace.screen == .place(.knowledge))
        navigator.goForward()
        #expect(workspace.screen == .place(.dashboard))
        #expect(!navigator.canGoForward)
    }

    @Test func unavailableEntriesAreSkippedInBothDirections() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        let session = WorkbenchScreen.session(UUID())
        let transcription = WorkbenchScreen.transcribe(UUID())
        await workspace.visit(.place(.recent), navigator: navigator)
        await workspace.visit(session, navigator: navigator)
        await workspace.visit(transcription, navigator: navigator)
        await workspace.visit(.place(.knowledge), navigator: navigator)
        workspace.unavailable = [session, transcription]

        navigator.goBack()
        #expect(workspace.screen == .place(.recent))
        #expect(!navigator.canGoBack)
        navigator.goForward()
        #expect(workspace.screen == .place(.knowledge))

        workspace.unavailable = []
        await workspace.visit(session, navigator: navigator)
        await workspace.visit(transcription, navigator: navigator)
        navigator.goBack()
        navigator.goBack()
        workspace.unavailable = [session]
        navigator.goForward()
        #expect(workspace.screen == transcription)
    }

    @Test func exhaustedUnavailableHistoryKeepsTheCurrentWorkspace() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        await workspace.visit(.place(.recent), navigator: navigator)
        await workspace.visit(.place(.knowledge), navigator: navigator)
        workspace.unavailable = [.place(.recent)]

        navigator.goBack()
        #expect(workspace.screen == .place(.knowledge))
        #expect(!navigator.canGoBack)
        #expect(!navigator.canGoForward)
    }

    @Test func routeChangesInOneTurnAreCoalesced() async {
        let workspace = Workspace()
        let navigator = workspace.makeNavigator()
        await workspace.visit(.place(.recent), navigator: navigator)
        workspace.screen = .session(UUID())
        navigator.note(workspace.screen)
        let dub = WorkbenchScreen.dub(UUID())
        workspace.screen = dub
        navigator.note(dub)

        navigator.goBack()
        #expect(workspace.screen == .place(.recent))
        #expect(!navigator.canGoBack)
        navigator.goForward()
        #expect(workspace.screen == dub)
    }

    @Test func editorHistoryIdentifiesTheActualProject() {
        let first = NSObject()
        let second = NSObject()
        let firstScreen = WorkbenchScreen.capture(
            editorID: ObjectIdentifier(first), route: .recent,
            sessionID: nil, transcriptionID: nil, dubID: nil
        )
        let secondScreen = WorkbenchScreen.capture(
            editorID: ObjectIdentifier(second), route: .recent,
            sessionID: nil, transcriptionID: nil, dubID: nil
        )
        #expect(firstScreen == .editor(ObjectIdentifier(first)))
        #expect(firstScreen != secondScreen)
    }

    @MainActor
    private final class Workspace {
        var screen: WorkbenchScreen = .place(.recent)
        var unavailable: [WorkbenchScreen] = []

        func makeNavigator() -> WorkbenchNavigator {
            WorkbenchNavigator(
                captureScreen: { self.screen },
                applyScreen: { target in
                    guard !self.unavailable.contains(target) else { return nil }
                    self.screen = target
                    return target
                }
            )
        }

        func visit(_ screen: WorkbenchScreen, navigator: WorkbenchNavigator) async {
            self.screen = screen
            navigator.note(screen)
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}
