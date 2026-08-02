# Contributing

## How to contribute

The best way to contribute is to open a Github issue. Bug reports, feature requests, ideas are welcome.

With AI coding, human reviews are the bottleneck. We don't have the bandwidth to review large unsolicited PRs.

## Getting Started

### Prerequisites
- macOS 26+
- Xcode 16+
- Swift 6.2 toolchain

### Develop
```bash
git clone https://github.com/palmier-io/palmier-pro
cd palmier-pro

swift build
swift run
```

`swift run` is suitable for UI and non-credential work. It has no stable code
signature, so it must not be used to validate Keychain-backed API keys.

For a bundled debug build that launches the `.app` and streams OSLog:

```bash
SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/dev.sh
```

## Test

```bash
swift test
```

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).
