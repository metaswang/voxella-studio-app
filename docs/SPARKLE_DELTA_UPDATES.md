# Sparkle In-App Updates with Binary Delta Implementation

## Overview

VoxStudio now uses Sparkle 2.9.2 for in-app updates with binary delta support for efficient incremental updates.

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
- Binary delta patches for efficient incremental updates
- Full DMG always available as fallback

## Build Configuration

### Package.swift
```swift
.trait(name: "SparkleUpdates", description: "Link Sparkle.framework for in-app updates")
```

Non-MAS builds automatically enable `SparkleUpdates` trait.

### bundle.sh
- Embeds `Sparkle.framework` from SwiftPM build output into `Contents/Frameworks/`
- MAS builds explicitly reject Sparkle embedding/linking
- Direct distribution builds require Sparkle.framework present

### Code Integration
```swift
#if SPARKLE_UPDATES && !MAC_APP_STORE
    // Uses SPUStandardUpdaterController
    static let shared: any AppUpdateControlling = SparkleAppUpdater.shared
#else
    // Falls back to legacy AppUpdater for website/MAS
    static let shared: any AppUpdateControlling = LegacyAppUpdater.shared
#endif
```

## Release Process with Deltas

### Archive Retention
- Last 5 full DMGs retained in `.build/release-archives/`
- Format: `{version}-{build}-{sha256_8}.dmg`
- Automatic cleanup of older archives

### Appcast Generation

#### Option 1: Sparkle generate_appcast (Recommended)
```bash
./scripts/generate_delta_appcast.sh \
  --archives-dir .build/release-archives \
  --output appcast-with-deltas.xml \
  --max-archives 5
```

Sparkle's `generate_appcast` tool automatically:
- Computes binary deltas between versions
- Signs deltas with EdDSA key
- Injects `<sparkle:deltas>` into items
- Handles version comparison

### R2 Release Flow
```bash
# Enable archive retention
RELEASE_TARGET=r2 ./scripts/release.sh
```

The `--enable-archives` flag is now automatic in `release.sh` for r2 targets.

## Appcast Structure

### Full Item with Deltas
```xml
<item>
    <title>Version 7.0.24</title>
    <sparkle:version>105</sparkle:version>
    <sparkle:shortVersionString>7.0.24</sparkle:shortVersionString>
    <enclosure url="...VoxStudio.dmg" length="91771362" sparkle:edSignature="..."/>
    <sparkle:deltas>
        <enclosure url="...7.0.23-104.delta" length="5234567"
            sparkle:deltaFrom="7.0.23" sparkle:version="104"/>
    </sparkle:deltas>
</item>
```

## Migration Notes

### First Sparkle-Enabled Build (Critical)
⚠️ **The first build with embedded Sparkle.framework must be a full DMG update.**

Old installs (without Sparkle) cannot apply `.delta` patches. Workflow:
1. Ship version N with Sparkle.framework embedded (no deltas yet)
2. Wait for adoption
3. Ship version N+1 with deltas from version N
4. Future updates use deltas

## Performance Benefits

Example: 7.0.23 (80MB) → 7.0.24 (82MB) with 2MB code changes
- Full download: 82 MB
- Delta patch: ~3-8 MB (BinaryDelta compression)
- Savings: ~75 MB (90% reduction)

## References

- Sparkle 2 Documentation: https://sparkle-project.org/documentation/
- Delta Updates Guide: https://sparkle-project.org/documentation/delta-updates/
- Publishing Guide: https://sparkle-project.org/documentation/publishing/
