# Sparkle In-App Updates Migration Runbook

## Overview

This document covers the migration from legacy browser-based DMG downloads to Sparkle 2.x in-app updates with binary delta support for VoxStudio Mac (Developer ID distribution).

## Breaking Changes

### For End Users
- **First Sparkle-enabled update**: Requires full DMG download (existing behavior)
- **Subsequent updates**: In-app installation via Sparkle UI (no browser navigation)
- **Old clients (pre-Sparkle)**: Continue seeing informational updates with manual browser download

### For Release Process
- **Archive retention**: Last 5 DMGs automatically retained in `.build/release-archives/`
- **First release constraint**: Ships full-DMG-only appcast (no deltas)
- **Delta workflow**: Manual integration required for delta generation and upload

## Migration Sequencing (Critical)

### Step 1: First Sparkle-Enabled Release (N)

**Critical constraint**: Old clients (pre-Sparkle) **cannot** apply binary deltas. This release must ship with **full DMG only**.

1. ✅ Embed Sparkle.framework in Developer ID builds
2. ✅ Use `SPUStandardUpdaterController` for in-app updates
3. ✅ Publish appcast with full DMG enclosure (no `<sparkle:deltas>`)
4. ✅ Archive the notarized DMG in `.build/release-archives/`

**Result**: Clients upgrade to Sparkle-enabled builds via full DMG.

### Step 2: Second Release (N+1) - Delta Eligibility

Now that clients have Sparkle embedded, deltas can be offered:

1. Archive from N is available in `.build/release-archives/`
2. **Manual workflow** (requires macOS):
   - Run `scripts/generate_delta_appcast.sh` to generate deltas
   - Upload `.delta` files to R2
   - Merge delta appcast into promoted appcast
3. Clients that installed N can apply delta patch
4. Clients still on pre-N download full DMG

## Runbook Updates

### Bundle Verification (bundle.sh)

**Updated checks:**

```bash
# MAS builds must not contain Sparkle
if [ "$MODE" = "mas" ]; then
  if [ -e "$APP/Contents/Frameworks/Sparkle.framework" ] \
      || otool -L "$APP/Contents/MacOS/VoxStudio" | grep -q Sparkle; then
    echo "!! Mac App Store builds must not embed or link Sparkle" >&2
    exit 1
  fi
fi

# Direct distribution builds must contain Sparkle
if [ "$MODE" != "mas" ]; then
  if [ ! -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    echo "!! Direct distribution builds require Sparkle.framework in Frameworks/" >&2
    exit 1
  fi
  if ! otool -L "$APP/Contents/MacOS/VoxStudio" | grep -q Sparkle; then
    echo "!! Direct distribution builds must link Sparkle" >&2
    exit 1
  fi
fi

# Provisioning profile must be present
if [ ! -e "$APP/Contents/embedded.provisionprofile" ]; then
  echo "!! signed app is missing embedded.provisionprofile" >&2
  exit 1
fi
```

**New step: Sign Sparkle.framework inside-out**

```bash
if [ "$MODE" != "mas" ] && [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "==> Codesigning Sparkle.framework"
  # Sign XPCServices if present
  for xpc in "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"/*.xpc; do
    [ -e "$xpc" ] && codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$xpc"
  done
  # Sign the framework itself
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    "$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    "$APP/Contents/Frameworks/Sparkle.framework"
fi
```

### Archive Management (r2_release.py)

**Updated behavior with `--enable-archives` (default on for R2 releases):**

```python
if archive_dir:
    archive_dir.mkdir(parents=True, exist_ok=True)
    archive_name = f"{manifest.version}-{manifest.build}-{manifest.sha256[:8]}.dmg"
    archive_path = archive_dir / archive_name
    if not archive_path.exists():
        link_or_copy(staged_dmg, archive_path)
    
    # Retain only the last N archives
    archives = sorted(
        archive_dir.glob("*.dmg"),
        key=lambda p: p.stat().st_mtime,
        reverse=True
    )
    for old_archive in archives[ARCHIVE_RETENTION_COUNT:]:
        old_archive.unlink()
```

### Delta Generation (Automated on macOS)

**Status**: Fully automated in R2 release flow

The `r2_release.py` prepare stage automatically:
1. Detects if delta generation is feasible (≥2 archives + macOS)
2. Invokes Sparkle's `generate_appcast` with EdDSA private key
3. Rewrites delta URLs to public CDN path: `{origin}/downloads/voxstudio/releases/{version}-{build}/{sha256}/deltas/{filename}`
4. Merges `<sparkle:deltas>` into base appcast while preserving full DMG enclosure
5. Uploads `.delta` files to R2 object keys: `app-releases/voxstudio/releases/{version}-{build}/{sha256}/deltas/{filename}`
6. Verifies delta URLs during verify stage

**Gate**: `RELEASE_ENABLE_DELTAS` environment variable (default: `auto`)
- `auto`: Enable when archive count ≥ 2 AND host is Darwin
- `0`: Force disable (first release or troubleshooting)
- `1`: Force enable (errors if prerequisites not met)

**No manual steps required** on macOS release machines.

## Testing Plan

### Pre-Release (Development)

1. **Build verification**:
   ```bash
   ./scripts/bundle.sh debug --sign
   # Verify: Sparkle.framework present in Contents/Frameworks/
   # Verify: otool -L shows Sparkle linkage
   # Verify: codesign --verify --deep --strict passes
   ```

2. **Settings pane**:
   - Toggle "Automatically check for updates"
   - Click "Check Now"
   - Verify: No compile errors, Settings pane renders

3. **MAS build exclusion**:
   ```bash
   # MAS build must reject Sparkle
   MODE=mas ./scripts/bundle.sh debug --sign
   # Expected: Build fails with Sparkle embedding error
   ```

### First Sparkle Release (N)

1. **Full DMG only**: Confirm appcast contains no `<sparkle:deltas>`
2. **Client upgrade**: Install on a test Mac, verify in-app Sparkle UI appears
3. **Archive retention**: Verify `.build/release-archives/` contains the DMG

### Second Release (N+1) - Delta Test

1. **Delta generation**: Run `generate_delta_appcast.sh`, verify `.delta` files created
2. **Upload test**: Manually upload deltas to R2, verify URLs resolve
3. **Client delta update**: From N→N+1, verify Sparkle applies delta (watch Installer log)
4. **Fallback test**: Delete delta files from R2, verify Sparkle falls back to full DMG

## Rollback Plan

### If Sparkle integration breaks production

1. Revert to commit before Sparkle changes
2. Publish emergency release without Sparkle.framework
3. Appcast reverts to informational updates (browser DMG download)
4. Investigate root cause offline

### If delta generation fails

1. Deltas are optional; full DMG always available
2. Ship full-DMG-only appcast (same as first release)
3. Archive retention continues for future attempts

## Known Limitations

1. **macOS-Only Delta Generation**: `generate_appcast` and BinaryDelta require macOS
   - Automated gate detects platform: Linux releases skip deltas automatically (`RELEASE_ENABLE_DELTAS=auto`)
2. **First-Release Full-Only**: Binary deltas unavailable until N+1
   - Enforced by archive count gate (< 2 archives → no deltas)
3. **EdDSA Private Key Required**: Must be in `~/.config/sparkle/sparkle_eddsa_priv.pem` (default Sparkle location)

## Post-Migration Monitoring

### Metrics to Track

- **Update adoption rate**: Sparkle analytics (if enabled)
- **Delta success rate**: Proportion of delta vs. full DMG downloads
- **Fallback rate**: How often deltas fail and trigger full DMG fallback
- **Bandwidth savings**: Compare delta vs. full DMG traffic

### Common Issues

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| "Download button" in Settings with Sparkle linked | `openDownload()` still uses browser | Fixed: Now calls `updaterController?.checkForUpdates()` |
| MAS build contains Sparkle | `bundle.sh` trait check failed | Verify `MODE=mas` excludes `SparkleUpdates` trait |
| Sparkle check fails after install | Framework not signed | Fixed: Inside-out signing in `bundle.sh` |
| Delta update fails | Signature mismatch or corrupt delta | Fall back to full DMG (automatic) |

## References

- `Sources/VoxstudioPro/App/AppUpdater.swift` — Sparkle integration
- `scripts/bundle.sh` — Framework embedding + signing
- `scripts/r2_release.py` — Archive retention
- `scripts/generate_delta_appcast.sh` — Delta generation script
- `docs/SPARKLE_DELTA_UPDATES.md` — Technical overview
