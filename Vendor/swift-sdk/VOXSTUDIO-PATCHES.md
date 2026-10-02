# VoxStudio SDK patch

Upstream: modelcontextprotocol/swift-sdk 0.12.1, commit a0ae212ebf6eab5f754c3129608bc5557637e605.
Retain upstream LICENSE and tests. No embedded Git repository.

- JSON-valued capabilities.extensions and client experimental.
- Typed server sendRequest with timeout and pre-registration cancellation handling.
- RequestContext propagates parent cancellation; server termination drains waiting requests.
- Responses remove timers; cancellation resumes locally before advisory notification.

See Tests/MCPTests/VoxStudioExtensionsTests.swift.
