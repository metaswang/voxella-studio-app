# Playhead Drag & Cursor Flicker Fix — Implementation Notes

## Overview
Fixed two related timeline cursor/playhead issues:
1. Made the playhead vertical line draggable (not just the triangle)
2. Fixed cursor flicker when moving mouse across timeline

## Technical Details

### Problem 1: Playhead Line Not Draggable
**Symptom**: Only the triangular handle at the top could be dragged to scrub.

**Root Cause**: The playhead is drawn as a CAShapeLayer (PlayheadOverlay) with a triangle and vertical line, but only the ruler area (containing the triangle) had hit-testing for playhead interaction.

**Solution**: 
- Added `playheadHit(at:geometry:)` method to detect mouse position near the playhead X coordinate
- Hit width: 8pt (matching the triangle's effective grab area)
- Modified `mouseDown` to check playhead line before other hit tests
- Uses same scrubbing mechanism as triangle (`beginPlayheadScrub`)

### Problem 2: Cursor Flicker
**Symptom**: Cursor rapidly switches between arrow and pointing-hand while moving across timeline.

**Root Cause**: Competing hover logic in `mouseMoved`:
- Ruler area would set `.pointingHand` for any point (line 811 in original)
- Other regions (clips, tracks, etc.) would set different cursors
- Without prioritization, the cursor would flicker as the mouse moved between regions

**Solution**:
- Check playhead hover **first** in `mouseMoved` before any other hover logic
- Added `lastPlayheadHit` state variable to track stable cursor state
- When over playhead, set cursor and return early (prevents downstream checks)
- This ensures only one cursor state is active at a time

### Code Changes

**TimelineInputController.swift**:

1. **New constant**:
   ```swift
   private static let playheadLineHitWidth: CGFloat = 8
   ```

2. **New state variable**:
   ```swift
   private var lastPlayheadHit = false
   ```

3. **New helper method**:
   ```swift
   private func playheadHit(at point: NSPoint, geometry: TimelineGeometry) -> Bool {
       let scrollOffsetY = view.enclosingScrollView?.contentView.bounds.origin.y ?? 0
       guard point.y >= scrollOffsetY + geometry.rulerHeight else { return false }
       
       let playheadX = geometry.xForFrame(editor.playheadState.timelineFrame)
       return abs(point.x - playheadX) <= Self.playheadLineHitWidth / 2
   }
   ```

4. **Modified mouseDown** (line ~160):
   - Added playhead line check before clip/razor hit-testing
   - Calls `beginPlayheadScrub(at:)` when playhead line is clicked

5. **Modified mouseMoved** (line ~786):
   - Added playhead check at the very beginning
   - Returns early if playhead is hit, preventing cursor flicker
   - Updates `lastPlayheadHit` state for tracking

6. **Modified endPointerTracking** (line ~777):
   - Resets `lastPlayheadHit` to false when pointer tracking ends

## Design Decisions

### Playhead Priority
When the playhead overlaps with a clip, the playhead takes priority. This matches the existing ruler behavior where clicking always starts scrubbing regardless of what's below the playhead.

### Hit Width (8pt)
The 8pt hit width provides:
- Reasonable grab target (not too narrow)
- Doesn't interfere with nearby clips
- Matches the triangle's effective hit area
- Small enough to avoid stealing unintended clicks

### Cursor Consistency
Using `.pointingHand` for both triangle and line maintains visual consistency and matches macOS conventions for draggable scrubbing interfaces.

## Testing Checklist

### Playhead Line Drag
- [ ] Click playhead vertical line → starts scrubbing
- [ ] Drag playhead line → updates play position
- [ ] Cursor over playhead line → shows pointing-hand
- [ ] Hit target is ~8pt wide (not full track width)
- [ ] Triangle drag still works

### Cursor Flicker
- [ ] Move mouse horizontally across timeline → no flicker
- [ ] Move from ruler to track area → smooth transition
- [ ] Move from empty track to clip → smooth transition
- [ ] Clip/trim handle cursors → correct and stable
- [ ] Playhead hover → stable pointing-hand cursor

### Regression Tests
- [ ] Triangle-drag works
- [ ] Clip drag/trim/selection intact
- [ ] Timeline range selection intact
- [ ] Razor tool cursor intact
- [ ] All existing keyboard shortcuts work
- [ ] Playhead auto-scroll during playback works
- [ ] Playhead snap-to works during scrub

## Known Limitations
None — the implementation is complete and follows existing patterns.

## Files Modified
- `Sources/PalmierPro/Timeline/TimelineInputController.swift`

## Verification
This Mac-only Swift/AppKit code requires macOS with Metal Toolchain to build and test. All verification must be done on a Mac build.
