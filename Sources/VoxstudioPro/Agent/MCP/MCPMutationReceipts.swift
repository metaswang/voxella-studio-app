import Foundation
import MCP

/// Shared by all HTTP sessions. A lost response can retrieve the original task's result.
@MainActor
final class MCPMutationReceipts {
    private struct Receipt {
        let fingerprint: Value
        let access: KnowledgeScopeSnapshot
        let created: Date
        let task: Task<CallTool.Result, Never>
        let context: MCPOpenAIExtensions?
    }
    private var receipts: [String: Receipt] = [:]
    private let capture: () async -> KnowledgeScopeSnapshot
    init(capture: @escaping () async -> KnowledgeScopeSnapshot = { await KnowledgeScopeSnapshot.capture(scope: .all, origins: nil) }) { self.capture = capture }
    func execute(_ params: CallTool.Parameters, context: MCPOpenAIExtensions? = nil, operation: @escaping @MainActor () async -> CallTool.Result) async -> CallTool.Result {
        guard let requestID = params.arguments?["request_id"]?.stringValue, UUID(uuidString: requestID) != nil else {
            return MCPWorkspaceTools.result(["error": "A write requires a stable UUID request_id. Preserve it when retrying.", "code": "request_id_required"], error: true)
        }
        receipts = receipts.filter { Date().timeIntervalSince($0.value.created) < 3600 }
        let fingerprint: Value = ["tool": .string(params.name), "arguments": .object(params.arguments ?? [:])]
        if let prior = receipts[requestID] {
            do { try await prior.access.validateAccess() }
            catch { receipts.removeValue(forKey: requestID); return MCPWorkspaceTools.result(["error": "Account access changed; the prior write cannot be replayed.", "code": "authorization_changed"], error: true) }
            guard prior.fingerprint == fingerprint else { return MCPWorkspaceTools.result(["error": "request_id already identifies another write", "code": "request_conflict"], error: true) }
            let result = await prior.task.value
            do { try await prior.access.validateAccess() }
            catch { return MCPWorkspaceTools.result(["error": "Account access changed while the write was running", "code": "authorization_changed"], error: true) }
            if let previous = prior.context { context?.recoverGrants(from: previous, result: result, access: prior.access) }
            return result
        }
        // Never evict a receipt within its retry lifetime: that could repeat a write.
        guard receipts.count < 256 else { return MCPWorkspaceTools.result(["error": "Write receipt capacity reached. Retry after receipts expire.", "code": "receipt_limit"], error: true) }
        let access = await capture()
        // Recheck after capture's actor hop so concurrent retries share one task.
        if receipts[requestID] != nil { return await execute(params, context: context, operation: operation) }
        let task = Task { await operation() }
        receipts[requestID] = Receipt(fingerprint: fingerprint, access: access, created: Date(), task: task, context: context)
        let result = await task.value
        do { try await access.validateAccess() }
        catch { return MCPWorkspaceTools.result(["error": "Account access changed while the write was running", "code": "authorization_changed"], error: true) }
        if let context { context.recoverGrants(from: context, result: result, access: access) }
        return result
    }
    /// Bootstrap before the UI bundle runs: hosts can delay or omit tool-result metadata.
    /// Names come from this connection's catalog and convey no authorization.
    nonisolated static func panelHTML(_ html: String, receiptTools: [String]?) throws -> String {
        guard let receiptTools else { return html }
        let json = String(decoding: try JSONEncoder().encode(receiptTools), as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
        guard let head = html.range(of: "<head>") else { return html }
        return html.replacingCharacters(in: head, with: "<head><script>window.__voxstudioReceiptTools=\(json);</script>")
    }

    nonisolated static func tool(_ tool: Tool) -> Tool {
        guard tool.annotations.readOnlyHint != true else { return tool }
        var schema = tool.inputSchema.objectValue ?? [:]
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["request_id"] = ["type": "string", "description": "Stable UUID for this write; preserve on retries. Receipts expire after one hour; do not retry an unknown write after that."]
        schema["properties"] = .object(properties)
        schema["required"] = .array(Array(Set((schema["required"]?.arrayValue ?? []) + [.string("request_id")])).sorted { String(describing: $0) < String(describing: $1) })
        return Tool(name: tool.name, title: tool.title, description: tool.description, inputSchema: .object(schema), annotations: tool.annotations, outputSchema: tool.outputSchema, _meta: tool._meta)
    }
}
