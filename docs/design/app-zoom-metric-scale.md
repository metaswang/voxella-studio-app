# App Zoom — Posture 3 Metric Scaling

## Problem
`scaleEffect` scales rendering only. SwiftUI layout / hit-testing stay at unscaled size → clicks and hover miss the painted controls.

## Approach
1. Keep `AppZoomScale.shared.scale` (0.8…1.5) and View menu Zoom In/Out/Reset.
2. **No** app-chrome `scaleEffect` / `AppPageZoomLayout` inverse layout.
3. Scale layout metrics: `AppTheme.Spacing` / `Radius` / `FontSize` / `IconSize` (and key window sizes) multiply by `AppTheme.appZoomScaleFactor`.
4. Inject `@Environment(\.appZoomScale)` at top-level surfaces; `.appZoomEnvironment()` keeps the live zoom value available without resetting view state.
5. Sheets / floating panels: `contentSize` from **measured layout** (already metric-scaled).
6. Timeline `editor.zoomScale` remains a separate canvas zoom track.

## Verify
Main window, Knowledge Base, Settings, Processing sheet, Voice Input at 0.8 / 1.0 / 1.5 — button and hover targets align with painted chrome; `NSTextView` composers included.
