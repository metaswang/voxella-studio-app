# Sparkle In-App Updates with Binary Delta Implementation

## Overview

VoxStudio now uses Sparkle 2.9.2 for in-app updates with binary delta support. This document describes the implementation status and integration points.

## Architecture Changes

### Before (Legacy)
- Custom AppUpdater parsed Sparkle-shaped appcast
- Opened full DMG download URL in browser (NSWorkspace.open)
- No framework linked; CLI tools only for signing
- Policy: "Sparkle installer is not linked"

### After (Current)
- **Direct distribution (Developer ID)**: Sparkle.framework embedded and linked
- **Mac App Store**: No Sparkle (MAS updates via App Store)
- Uses SPUStandardUpdaterController for true in-app updates
- Binary delta patches for efficient incremental updates (manual workflow)
- Full DMG always available as fallback

## Build Configuration

### Package.swift
```swift
.trait(name: "SparkleUpdates", description: "Link Sparkle.framework for in-app updates")
```

Non-MAS builds automatically enable `SparkleUpdates` trait.

### bundle.sh
- Embeds `Sparkle.framework` from SwiftPM build output into `Contents/Frameworks/`
- Signs Sparkle.framework inside-out before signing the app
- MAS builds explicitly reject Sparkle embedding/linking
- Direct distribution builds require Sparkle.framework present

### Code Integration
```swift
@MainActor @Observable
final class AppUpdater {
    #if SPARKLE_UPDATES && !MAC_APP_STORE
        private var updaterController: SPUStandardUpdaterController?
        // In-app updates via Sparkle
    #else
        // Falls back to legacy browser-based DMG download
    #endif
}
```

## Release Process with Deltas

### Archive Retention (Implemented)
- Last 5 full DMGs retained in `.build/release-archives/`
- Format: `{version}-{build}-{sha256_8}.dmg`
- Automatic cleanup of older archives
- Enabled via `--enable-archives` in `r2_release.py` (default on for R2 releases)

### Delta Generation (Manual Workflow)

**Status**: Script available, requires manual macOS integration

```bash
./scripts/generate_delta_appcast.sh \
  --archives-dir .build/release-archives \
  --output /tmp/appcast-with-deltas.xml \
  --private-key ~/.config/sparkle/sparkle_eddsa_priv.pem \
  --download-url-prefix https://assets.voxstudio.me/app-releases/voxstudio/VERSION-BUILD-SHA
```

Sparkle's `generate_appcast` tool automatically:
- Computes binary deltas between versions
- Signs deltas with EdDSA key
- Injects `<sparkle:deltas>` into items
- Outputs `.delta` files to temp directory

**Requirements:**
- At least 2 archived DMGs (first release skips deltas)
- macOS machine (BinaryDelta requires macOS)
- EdDSA private key in `~/.config/sparkle/sparkle_eddsa_priv.pem`

### R2 Release Flow

```bash
# Enables archive retention for future delta generation
RELEASE_TARGET=r2 ./scripts/release.sh
```

**Current behavior:**
1. ✅ Builds and notarizes DMG
2. ✅ Archives DMG for future delta generation
3. ✅ Uploads full DMG to R2 with immutable versioned URL
4. ✅ Publishes appcast with full DMG enclosure
5. ❌ **Delta generation and upload: Manual workflow required**

## Appcast Structure

### Full DMG (Always Present)

```xml
<enclosure
    url="https://assets.voxstudio.me/app-releases/voxstudio/0.4.8-46-a1b2c3d4/VoxStudio.dmg"
    length="167890123"
    type="application/octet-stream"
    sparkle:edSignature="..." />
```

### Delta Updates (Manual Addition)

```xml
<sparkle:deltas>
    <enclosure
        url="https://assets.voxstudio.me/app-releases/voxstudio/0.4.8-46-a1b2c3d4/delta-from-0.4.7-45.delta"
        length="8901234"
        type="application/octet-stream"
        sparkle:edSignature="..."
        sparkle:deltaFrom="0.4.7-45" />
</sparkle:deltas>
```

## Migration Sequencing

### First Sparkle-Enabled Release (N)

1. ✅ Ship full DMG with embedded Sparkle.framework
2. ✅ Appcast contains only full DMG enclosure (no deltas)
3. Old clients (pre-Sparkle) see informational update; manual browser download
4. New clients (with Sparkle) install in-app via full DMG
5. Archive retained for future delta generation

### Second Release (N+1) - Delta Workflow

1. Archive from N available in `.build/release-archives/`
2. **Manual step**: Run `generate_delta_appcast.sh` on macOS
3. **Manual step**: Upload generated `.delta` files to R2
4. **Manual step**: Merge delta appcast into promoted appcast
5. Clients that installed N can apply delta; others download full DMG

## Performance

- **Full DMG**: ~160MB notarized disk image
- **Delta**: ~8-15MB (typical patch, depends on changes)
- **Savings**: ~90% bandwidth reduction for incremental updates

## Known Limitations

1. **macOS-Only Tooling**: `generate_appcast` and BinaryDelta require macOS; Linux cloud VM cannot generate deltas
2. **Manual Delta Upload**: `.delta` files must be manually uploaded to R2; automated upload not yet implemented
3. **First-Release Full-Only**: Old clients cannot apply deltas until they upgrade to a Sparkle-enabled build
4. **R2 Delta Integration**: Requires defining delta URL scheme and updating upload/verify stages

## References

- [Sparkle 2.x Documentation](https://sparkle-project.org/documentation/)
- [BinaryDelta](https://github.com/sparkle-project/Sparkle/tree/2.x/BinaryDelta)
- `scripts/generate_delta_appcast.sh` — Delta appcast generation script
- `scripts/r2_release.py` — Archive retention (`--enable-archives`)
- `docs/MIGRATION_SPARKLE.md` — Deployment checklist
