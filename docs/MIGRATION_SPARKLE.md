# Migration Guide: Sparkle 2.x In-App Updates

## Summary of Changes

This update transitions VoxStudio from custom "parse appcast + open DMG in browser" to real Sparkle 2.x in-app updates with BinaryDelta incremental upgrades.

## Breaking Changes

### Policy Reversal
**Before**: "The Sparkle installer is not linked"
**After**: Sparkle.framework is embedded and linked for Developer ID builds

### Bundle Verification
Old check (removed):
```bash
if [ -e "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "!! Sparkle must not be embedded" >&2
  exit 1
fi
```

New check (bundle.sh):
```bash
if [ "$MODE" = "mas" ]; then
  # MAS must NOT have Sparkle
  if [ -e "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    echo "!! Mac App Store builds must not embed or link Sparkle" >&2
    exit 1
  fi
else
  # Direct distribution MUST have Sparkle
  if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    echo "!! Direct distribution builds require Sparkle.framework" >&2
    exit 1
  fi
fi
```

## Release Runbook Updates

### 1. First Sparkle Build (Critical Path)

⚠️ **The first release with embedded Sparkle cannot offer deltas.**

Sequence:
1. **Release v7.1.0** (first with Sparkle.framework)
   - Full DMG only, no deltas in appcast
   - All users download complete 80MB DMG
2. **Wait for adoption** (monitor download metrics)
3. **Release v7.1.1** (first with deltas)
   - Appcast includes `<sparkle:deltas>` from v7.1.0
   - Users on v7.1.0+ download 3-8MB delta

### 2. Archive Management

New directory: `.build/release-archives/`
- Retains last 5 full DMGs by mtime
- Format: `{version}-{build}-{sha256_8}.dmg`
- Used by `generate_appcast` for delta computation

### 3. Appcast Generation

Previous workflow (manual XML append) is replaced with:

```bash
./scripts/generate_delta_appcast.sh \
  --archives-dir .build/release-archives \
  --output appcast-with-deltas.xml
```

Sparkle's `generate_appcast` computes deltas automatically.

**Note**: Requires macOS (uses native APIs). Linux CI cannot run it.

## Testing Checklist

### Pre-Release
- [ ] Build with `--traits BundledSpeech,SparkleUpdates` succeeds
- [ ] `otool -L VoxStudio` shows `@rpath/Sparkle.framework/Versions/B/Sparkle`
- [ ] `codesign --verify --deep VoxStudio.app` passes
- [ ] Bundle check confirms Sparkle.framework present
- [ ] MAS build (`--mas`) rejects Sparkle successfully

### Post-Release (First Sparkle Build)
- [ ] Old users (v7.0.x) can download + install full DMG
- [ ] In-app update check triggers Sparkle UI (not browser)
- [ ] Update downloads, installs, and relaunches correctly

### Post-Release (First Delta Build)
- [ ] Appcast contains `<sparkle:deltas>` section
- [ ] Users on previous Sparkle version offered delta
- [ ] Delta applies successfully
- [ ] Fallback to full DMG works if delta fails

## Rollback Plan

If Sparkle causes critical issues:

1. **Immediate**: Revert Package.swift and bundle.sh changes
2. **Rebuild** without SparkleUpdates trait
3. **Publish** emergency release with custom AppUpdater restored

Files to revert:
- `Package.swift`
- `Sources/PalmierPro/App/AppUpdater.swift`
- `scripts/bundle.sh`

## Known Limitations

### 1. macOS Required for Delta Generation
Sparkle's `generate_appcast` uses macOS-only APIs. Linux CI cannot run it.

**Mitigation**: Mac release machine runs `generate_appcast` locally.

### 2. Old Clients Cannot Apply Deltas
Versions before first Sparkle-enabled release always download full DMG.

**Mitigation**: Expected behavior. Document in release notes.

## Sign-Off

Before merging:
- [ ] Code review
- [ ] Local build test (Debug, Release, MAS)
- [ ] Sparkle key verification
- [ ] Release team acknowledgment
