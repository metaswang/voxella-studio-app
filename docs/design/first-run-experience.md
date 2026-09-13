# First-run experience

The first-run flow introduces outcomes, asks which features to prepare on this Mac, and shows download progress before entering Dashboard. Nothing is preselected. A persisted completion flag suppresses the flow on later launches. Closing before completion preserves the selected features. Opening a project externally takes precedence over onboarding; returning home resumes the introduction. Replaying from Local Features does not reset the persisted completion flag or close a project.

## Visual design

The wizard is a centered 920 × 570 panel with a 430-point animated left section and a quiet right section. First launch uses a compact window and skips automatic window zoom. The feature introduction has no previous/next controls or pagination: two staggered columns move continuously in opposite directions. Cards contain caption snippets, voice waveforms, search, translation and timeline illustrations, with varied heights and slight rotation. Cards scale from 94% at the periphery to 124% at the center across a 140-point focal radius, expanding inward and sharing one cross-column stacking order; the top and bottom fade out before the loop wraps. Pause and Reduce Motion stop movement. AppKit application deactivation pauses the clock; resuming does not jump forward through elapsed background time. The AppKit-hosted view reads `NSApplication.isActive` on appearance and observes activation notifications instead of relying on a SwiftUI `scenePhase` environment.

The right section keeps setup navigation separate from the moving feature artwork. The introduction needs no scrolling; feature selection and resource preparation scroll independently when needed. New or invalid appearance preferences default to System. Saved explicit light/dark preferences are preserved.

The implementation is native SwiftUI with no video or web runtime. The original research compared [Swiper autoplay](https://swiperjs.com/swiper-api), [stacked cards](https://studio.swiperjs.com/templates/cards-swiper), and [Magic UI marquee](https://v3.magicui.design/docs/components/marquee). The current design follows the continuous multi-card direction. [Apple onboarding guidance](https://developer.apple.com/design/human-interface-guidelines/onboarding) informs the short, optional setup.

A static light-mode rendering is available in `artifacts/onboarding-preview/onboarding-light.png`. It renders the actual introduction and artwork with backend calls omitted; it is not end-to-end UI evidence.

## Ownership and dependencies

`OnboardingState` owns the step, selection and completion preferences on the main actor. `LocalPreparationFeature` maps user-facing capabilities to the existing task installation plans. `LocalModelManager` remains the authoritative owner of resource state, authorization, serial downloads, cancellation and restart recovery. The UI derives readiness and byte-weighted progress from that state and never displays transfer filenames or repository messages.

Transcription uses the existing automatic-language plan. Dubbing shares its alignment resource with transcription. Search is optional. Speaker identification retains its separate, explicit terms acceptance in Local Features. Visual search retains its existing downloader. Unselected transcription/dubbing resources are disclosed in the task options before the user submits the job. A cancelled task may leave an explicitly approved resource download running, as in the existing download contract.

Advanced AI service configuration stays available behind an initially collapsed disclosure. AI selection toolbars use an explicit advanced-options label; activity history shows the type of operation. Internal identifiers, task contracts, and persisted model choices remain unchanged.

## Manual verification required

Use a disposable macOS account or an isolated preference domain and test media; do not delete the user's preferences or resource cache.

1. Fresh launch: a compact window appears with several moving cards visible at once, without initiating downloads. Check both column directions, smooth looping at the faded edges, center enlargement and straightening, pause/resume, Tab focus and Return. Switch away and back: motion pauses without jumping. Enable Reduce Motion: the artwork stays still. Check English/Chinese and System appearance in both macOS light and dark modes.
2. Continue without selecting features, then Continue: Dashboard opens. Relaunch: no wizard. Local Features → Replay introduction: wizard returns; existing project stays recoverable.
3. Select transcription and dubbing: estimate counts shared resources once. Download: named features and progress appear without technical identities. Continue to Dashboard while downloading; resources remain visible in Local Features.
4. Interrupt networking, retry, cancel a queued and active download, close and reopen the app. Expect actionable failure/cancellation state and resumption of approved downloads. No successful readiness until every required resource is installed.
5. Skip dubbing, then create a local voiceover. Expect estimated download and “Download and generate” before task submission. Repeat with transcription. Once prepared, no new download prompt. Cloud tasks do not trigger local preparation.
6. Open a project externally during first-run setup. Expect the editor to open; returning home resumes the unfinished introduction without closing the project.
7. Open Local Features and inspect optional speaker identification terms, visual search, and all status states. Open AI Service: advanced provider and routing configuration is collapsed; manually expand to edit it.
8. Inspect captions, voice library, project activity, storage and AI toolbars. No technical names on their default surfaces. Test Escape/dismissal and keyboard focus in advanced menus and processing sheets.

UI outcomes remain unverified until a user performs these scenarios. Automated build and unit results are reported separately.

## Verification

- `swift build`: passed for the redesigned wizard.
- `swift test --filter 'AppAppearanceTests|OnboardingTests|FeatureWallMotionTests'`: 19 tests in 3 suites passed.
- English and Simplified Chinese `Localizable.strings` passed `plutil -lint`.
- The introduction was inspected using a SwiftUI offscreen static rendering. Native desktop automation timed out; moving UI, download flows and DMG installation still require manual verification. The installed application has not been replaced.
- No bundled speech code changed in this visual revision; BundledSpeech and the complete test suite were not rerun for this revision.

## Animation regression verification

The host is an AppKit `NSHostingController`, not a SwiftUI Scene. Playback now starts from the actual AppKit activation state. Deterministic clock tests cover an already-active host, activation after presentation, background time exclusion, manual pause across reactivation, Reduce Motion, and disappearance.

After rebuilding the app, force the introduction at launch. With Reduce Motion off and the app active, observe the two columns moving for several seconds and a card enlarging at the center. Click pause and confirm that positions stop; click play and confirm continuation. Switch to another app and back: movement should resume without a jump. Enable Reduce Motion and confirm a still wall. These interactive outcomes require user confirmation.

Center emphasis was checked with an offscreen render: the center card expands inward above the adjacent column without clipping its outer edge. Live motion still requires user confirmation after rebuilding the packaged app.
