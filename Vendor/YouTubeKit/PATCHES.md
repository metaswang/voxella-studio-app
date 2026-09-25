# Local patches

This vendored package is based on [YouTubeKit 0.4.9](https://github.com/alexeichhorn/YouTubeKit/tree/e5b7d0396ce12bf3444f0d209e8436c83373b7af).
The upstream MIT license is kept in `LICENSE`.

- `Sources/YouTubeKit/Parser.swift`: return an extraction error for an
  unexpected YouTube player JavaScript body instead of calling `fatalError()`.
- `Sources/YouTubeKit/Extensions/WebSocket.swift`: return an extraction error
  for an unknown WebSocket message kind instead of calling `fatalError()`.
- `Sources/YouTubeKit/Cipher.swift`: report regular-expression construction
  failure as an extraction error instead of force-unwrapping it with `try!`.

When upgrading YouTubeKit, review and reapply these changes before replacing
this local package dependency in the root `Package.swift`.
