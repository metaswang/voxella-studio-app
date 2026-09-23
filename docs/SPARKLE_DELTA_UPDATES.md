# Sparkle In-App Updates with Binary Delta Implementation

## Overview

VoxStudio now uses Sparkle 2.9.2 for in-app updates with **automated binary delta support**. Binary deltas reduce update download sizes by ~90% for incremental updates.

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
- **Automated binary delta patches** for efficient incremental updates
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

## Release Process with Automated Deltas

### Archive Retention (Implemented)
- Last 5 full DMGs retained in `.build/release-archives/`
- Format: `{version}-{build}-{sha256_8}.dmg`
- Automatic cleanup of older archives
- Enabled via `--enable-archives` in `r2_release.py` (default on for R2 releases)

### Delta Generation (Automated on macOS)

**Status**: Fully automated on macOS release machines

The release pipeline automatically:
1. Detects archive count (must be ≥ 2 for deltas)
2. Invokes Sparkle's `generate_appcast` tool to compute binary deltas
3. Rewrites delta URLs to public CDN path: `{origin}/downloads/voxstudio/releases/{version}-{build}/{sha256}/deltas/{filename}`
4. Merges `<sparkle:deltas>` into base appcast while preserving full DMG enclosure
5. Uploads `.delta` files to R2 object keys: `app-releases/voxstudio/releases/{version}-{build}/{sha256}/deltas/{filename}`
6. Verifies delta URLs are accessible

**Delta Generation Gate**: `RELEASE_ENABLE_DELTAS` environment variable
- `auto` (default): Enable when archive count ≥ 2 AND host is macOS
- `0`: Force disable (ships full-DMG-only appcast)
- `1`: Force enable (errors if < 2 archives or not macOS)

### R2 Release Flow

```bash
# Standard release (deltas enabled automatically on macOS when possible)
RELEASE_TARGET=r2 ./scripts/release.sh

# Force disable deltas (first Sparkle release)
RELEASE_ENABLE_DELTAS=0 RELEASE_TARGET=r2 ./scripts/release.sh

# Force enable deltas (will error if prerequisites not met)
RELEASE_ENABLE_DELTAS=1 RELEASE_TARGET=r2 ./scripts/release.sh
```

**Current behavior:**
1. ✅ Builds and notarizes DMG
2. ✅ Archives DMG for future delta generation
3. ✅ **Generates binary deltas** (auto, when ≥2 archives on macOS)
4. ✅ **Uploads `.delta` files to R2** with immutable URLs
5. ✅ **Merges deltas into appcast** while preserving full DMG enclosure
6. ✅ **Verifies delta URLs** during verify/postcheck stages
7. ✅ Publishes appcast with both full DMG and deltas

## Appcast Structure

### Full DMG (Always Present)

```xml
<enclosure
    url="https://assets.voxstudio.me/downloads/voxstudio/releases/0.4.8-46/a1b2c3d4/VoxStudio.dmg"
    length="167890123"
    type="application/octet-stream"
    sparkle:edSignature="..." />
```

### Delta Updates (Automated from N+1)

```xml
<sparkle:deltas>
    <enclosure
        url="https://assets.voxstudio.me/downloads/voxstudio/releases/0.4.8-46/a1b2c3d4/deltas/45-to-46.delta"
        length="8901234"
        type="application/octet-stream"
        sparkle:edSignature="..."
        sparkle:deltaFrom="45" />
</sparkle:deltas>
```

**Public Delta URL Scheme**: `{origin}/downloads/voxstudio/releases/{version}-{build}/{sha256}/deltas/{from-build}-to-{to-build}.delta`

**R2 Object Key**: `app-releases/voxstudio/releases/{version}-{build}/{sha256}/deltas/{filename}`

Where:
- Public URLs use `/downloads/voxstudio/...` path (served by Cloudflare worker)
- R2 object keys use `app-releases/voxstudio/...` prefix (internal storage)
- Immutable, versioned, no "latest" redirects

## Migration Sequencing

### First Sparkle-Enabled Release (N)

1. ✅ Ship full DMG with embedded Sparkle.framework
2. ✅ Appcast contains only full DMG enclosure (no deltas)
   - Enforced by gate: `RELEASE_ENABLE_DELTAS=auto` with archive count = 1
3. Old clients (pre-Sparkle) see informational update; manual browser download
4. New clients (with Sparkle) install in-app via full DMG
5. Archive retained for future delta generation

### Second Release (N+1) - Deltas Automated

1. Archive from N available in `.build/release-archives/`
2. ✅ **Automatic**: `r2_release.py` generates deltas via Sparkle `generate_appcast`
3. ✅ **Automatic**: Uploads `.delta` files to R2 with immutable URLs
4. ✅ **Automatic**: Merges `<sparkle:deltas>` into promoted appcast
5. Clients on N can apply delta; others download full DMG

## Performance

- **Full DMG**: ~160MB notarized disk image
- **Delta**: ~8-15MB (typical patch, depends on changes)
- **Savings**: ~90% bandwidth reduction for incremental updates

## Known Limitations

1. **macOS-Only Delta Generation**: `generate_appcast` and BinaryDelta require macOS
   - Gate detects platform: Linux releases ship full-DMG-only automatically
2. **First-Release Full-Only**: Old clients cannot apply deltas until they upgrade to a Sparkle-enabled build
   - Enforced by archive count gate (< 2 archives → no deltas)
3. **EdDSA Private Key Required**: Must be in `~/.config/sparkle/sparkle_eddsa_priv.pem` or specified location

## Troubleshooting

### Delta Generation Skipped

Check the release log for skip reason:
- `"first Sparkle release (archive count: 1, need ≥2)"` → Expected for first release
- `"not on macOS (BinaryDelta requires Darwin)"` → Run on macOS release machine
- `"disabled via RELEASE_ENABLE_DELTAS=0"` → Remove env override

### Delta Upload Failed

- Verify R2 credentials are set
- Check `.delta` files exist in staging: `.build/r2-release/{version}-{build}/{sha256}/deltas/`
- Confirm Sparkle tools available: `.build/sparkle-tools/bin/generate_appcast`

### Clients Not Applying Deltas

- Verify appcast contains `<sparkle:deltas>` element
- Confirm delta URLs are accessible (check verify stage output)
- Ensure full DMG enclosure is primary (Sparkle falls back on delta failure)

## References

- [Sparkle 2.x Documentation](https://sparkle-project.org/documentation/)
- [BinaryDelta](https://github.com/sparkle-project/Sparkle/tree/2.x/BinaryDelta)
- `scripts/r2_release.py` — Delta generation + upload automation
- `docs/MIGRATION_SPARKLE.md` — Deployment checklist
