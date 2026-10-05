import Foundation
import MCP
import Testing
@testable import VoxstudioPro

@MainActor private final class WriteCount { var value = 0 }

struct MCPWorkspaceTests {
    private func fixture() -> KnowledgeScopeSnapshot {
        let helper = KnowledgeEvidenceWorkspaceTests()
        return helper.snapshot([helper.fixture(title: "One"), helper.fixture(title: "Two")])
    }
    private func open(_ store: MCPWorkspaceStore, _ snapshot: KnowledgeScopeSnapshot) async throws -> String {
        try #require(try await store.open(id: nil, snapshot: snapshot).objectValue?["workspace_id"]?.stringValue)
    }
    private func begin(_ store: MCPWorkspaceStore, _ id: String, _ snapshot: KnowledgeScopeSnapshot) async throws -> String {
        try #require(try await store.begin(id: id, query: "Question", scope: [:], snapshot: snapshot, requestID: UUID().uuidString).objectValue?["turn_id"]?.stringValue)
    }
    @Test func lateParallelResultsCannotOverwriteReadingOrCompletedHistory() async throws {
        let snapshot=fixture(),store=MCPWorkspaceStore(),id=try await open(store,snapshot)
        let a=try await begin(store,id,snapshot),first=try await store.startOperation(id:id,turnID:a)
        let b=try await begin(store,id,snapshot),second=try await store.startOperation(id:id,turnID:b)
        let read: Value = ["segments": [["source_id": .string(snapshot.sessions[0].id.uuidString), "evidence_id": "read-a", "text": "Original"]]]
        let read2: Value = ["segments": [["source_id": .string(snapshot.sessions[1].id.uuidString), "evidence_id": "read-b", "text": "Second"]]]
        async let observationA=store.record(first,name:"fetch",arguments:[:],result:read,isError:false)
        async let observationB=store.record(second,name:"fetch",arguments:[:],result:read2,isError:false)
        _ = try await (observationA,observationB)
        let active=try await store.state(id:id,turnID:nil,after:nil).objectValue!
        #expect(active["turn_id"]?.stringValue==b)
        #expect(active["view"]?.objectValue?["source_id"]?.stringValue==snapshot.sessions[1].id.uuidString)
        _ = try await store.finish(id:id,turnID:b,evidence:["read-b"],observations:[],outcome:"answered")
        _ = try await begin(store,id,snapshot)
        let history=try await store.state(id:id,turnID:b,after:nil).objectValue!
        #expect(history["view"]?.objectValue?["source_id"]?.stringValue==snapshot.sessions[1].id.uuidString)
        #expect(history["cited_evidence_ids"]==["read-b"])
        #expect(try await store.record(second,name:"fetch",arguments:[:],result:read,isError:false)==nil)
    }
    @Test func unreadEvidenceIsRejectedAndFinishIsImmutableAndIdempotent() async throws {
        let snapshot=fixture(),store=MCPWorkspaceStore(),id=try await open(store,snapshot),turn=try await begin(store,id,snapshot)
        do { _ = try await store.finish(id:id,turnID:turn,evidence:["unread"],observations:[],outcome:"answered"); Issue.record("Accepted unread evidence") }
        catch { #expect((error as? WorkspaceError)?.code=="unread_evidence") }
        let operation=try await store.startOperation(id:id,turnID:turn)
        let observation=try #require(try await store.record(operation,name:"aggregate",arguments:[:],result:["count":2],isError:false))
        let done=try await store.finish(id:id,turnID:turn,evidence:[],observations:[observation],outcome:"answered")
        #expect(try await store.finish(id:id,turnID:turn,evidence:[],observations:[observation],outcome:"answered")==done)
        do { _ = try await store.finish(id:id,turnID:turn,evidence:[],observations:[],outcome:"failed"); Issue.record("Changed completed turn") }
        catch { #expect((error as? WorkspaceError)?.code=="turn_finished") }
    }
    @Test func lateCompletionKeepsItsOwnReadingViewAndFallsBackToCheckedSources() async throws {
        let snapshot=fixture(),store=MCPWorkspaceStore(),id=try await open(store,snapshot),a=try await begin(store,id,snapshot)
        let first=snapshot.sessions[0].id.uuidString,second=snapshot.sessions[1].id.uuidString
        let search=try await store.startOperation(id:id,turnID:a)
        _ = try await store.record(search,name:"search",arguments:[:],result:["results":[["source_id":.string(first)],["source_id":.string(second)]]],isError:false)
        let fetch=try await store.startOperation(id:id,turnID:a)
        _ = try await store.record(fetch,name:"fetch",arguments:[:],result:["segments":[["source_id":.string(second),"evidence_id":"checked-second","text":"Original"]]],isError:false)
        let b=try await begin(store,id,snapshot)
        _ = try await store.finish(id:id,turnID:a,evidence:["checked-second"],observations:[],outcome:"answered")
        let history=try await store.state(id:id,turnID:a,after:nil).objectValue!
        let active=try await store.state(id:id,turnID:nil,after:nil).objectValue!
        #expect(history["view"]?.objectValue?["source_id"]?.stringValue==second)
        #expect(active["turn_id"]?.stringValue==b)
        #expect(active["view"]?.objectValue?["source_id"]==nil)
        let readB=try await store.startOperation(id:id,turnID:b)
        _ = try await store.record(readB,name:"search",arguments:[:],result:["results":[["source_id":.string(first)]]],isError:false)
        let fetchB=try await store.startOperation(id:id,turnID:b)
        _ = try await store.record(fetchB,name:"fetch",arguments:[:],result:["segments":[["source_id":.string(second),"evidence_id":"checked-b","text":"Original"]]],isError:false)
        let done=try await store.finish(id:id,turnID:b,evidence:["checked-b"],observations:[],outcome:"answered").objectValue!
        #expect(done["view"]?.objectValue?["source_id"]?.stringValue==second)
    }
    @Test func manualFocusAndPinPersistWithOptimisticViewRevisionAndFrozenScope() async throws {
        let snapshot=fixture(),store=MCPWorkspaceStore(),id=try await open(store,snapshot),turn=try await begin(store,id,snapshot)
        let source=snapshot.sessions[0].id.uuidString
        _ = try await store.updateView(id:id,expected:1,values:["source_id":.string(source),"manual_turn_id":.string(turn),"pinned":true,"next_scope":["source_ids":[.string(source)]],"reading_view":"summary","anchor":3])
        do { _ = try await store.updateView(id:id,expected:0,values:["pinned":false]);Issue.record("Accepted stale view") }
        catch { #expect((error as? WorkspaceError)?.code=="view_conflict") }
        let next=try await begin(store,id,snapshot)
        let state=try await store.state(id:id,turnID:nil,after:nil).objectValue!
        #expect(state["view"]?.objectValue?["source_id"]?.stringValue==source)
        #expect(state["next_scope"]?.objectValue?["source_ids"]==[.string(source)])
        #expect(state["scope"] == .object([:]))
        #expect(state["turn_id"]?.stringValue==next)
    }
    @Test func requestReceiptExpiryCapacityAndScopeValidation() async throws {
        let snapshot=fixture(),store=MCPWorkspaceStore(capacity:1),id=try await open(store,snapshot),request=UUID().uuidString
        let first=try await store.begin(id:id,query:"same",scope:[:],snapshot:snapshot,requestID:request)
        #expect(try await store.begin(id:id,query:"same",scope:[:],snapshot:snapshot,requestID:request)==first)
        #expect(try await store.receiptWorkspace(requestID:request)==id)
        _ = try await open(store,snapshot)
        await #expect(throws: WorkspaceError.self) { try await store.state(id:id,turnID:nil,after:nil) }
        let expired=MCPWorkspaceStore(idleSeconds:0)
        let old=try await open(expired,snapshot)
        await #expect(throws: WorkspaceError.self) { try await expired.state(id:old,turnID:nil,after:nil) }
        #expect(try MCPWorkspaceTools.scope(["origin":"all"]).1==nil)
        #expect(throws: WorkspaceError.self) { try MCPWorkspaceTools.scope(["source_ids":[]]) }
    }
    @Test @MainActor func wrappersStripPresentationFieldsBeforeCursorHashingAndRejectBroaderScope() async throws {
        let snapshot=fixture(),tools=MCPWorkspaceTools(store:MCPWorkspaceStore(),capture:{ scope,_ in
            if scope == .all { return snapshot }
            let ids=Set(scope.sessionIDs),sources=snapshot.sessions.filter{ids.contains($0.id)}
            return KnowledgeScopeSnapshot(scope:scope,ownerID:snapshot.ownerID,sessions:sources,generations:snapshot.generations,isLive:false)
        })
        let opened=await tools.execute(.init(name:"app_knowledge",arguments:["action":"begin","query":"question","request_id":.string(UUID().uuidString),"scope":["source_ids":[.string(snapshot.sessions[0].id.uuidString)]]]))
        let id=try #require(opened.structuredContent?.objectValue?["workspace_id"]),turn=try #require(opened.structuredContent?.objectValue?["turn_id"])
        let listed=await tools.execute(.init(name:"list_sources",arguments:["workspace_id":id,"turn_id":turn]))
        #expect(listed.isError != true)
        let presentation=await tools.execute(.init(name:"knowledge.workspace_state",arguments:["workspace_id":id]))
        let observations=presentation.structuredContent?.objectValue?["observations"]?.objectValue
        #expect(observations?.values.first?.objectValue?["arguments"] == .object([:]))
        #expect(observations?.values.first?.objectValue?["sequence"]?.intValue == 0)
        #expect(listed.structuredContent?.objectValue?["sources"]?.arrayValue?.count==1)
        #expect(listed.structuredContent?.objectValue?["observation_id"] != nil)
        let forbidden=await tools.execute(.init(name:"fetch",arguments:["workspace_id":id,"turn_id":turn,"source_id":.string(snapshot.sessions[1].id.uuidString)]))
        #expect(forbidden.isError==true)
        let malformed=await tools.execute(.init(name:"fetch",arguments:["workspace_id":id]))
        #expect(malformed.isError==true)
        let data=MCPWorkspaceTools.tools.filter{MCPKnowledgeBaseTools.tools.map(\.name).contains($0.name)}
        #expect(data.allSatisfy{$0._meta==nil})
        #expect(MCPWorkspaceTools.tools.first{$0.name=="app_knowledge"}?._meta?["ui"]?.objectValue?["resourceUri"]?.stringValue==MCPAppPresentation.workspaceURI)
        let gateway = try #require(MCPWorkspaceTools.tools.first { $0.name == "app_evidence" })
        #expect(gateway._meta == nil)
    }
    @Test @MainActor func localEvidenceGatewayReadsVisibleSessionAndCompletesWithVerifiedCitations() async throws {
        let helper = KnowledgeEvidenceWorkspaceTests()
        let source = helper.fixture(title: "Origin of Writing", segments: [
            .init(text: "Irving Finkel discusses the origins of writing and ancient languages.", start: 0, end: 12)
        ])
        let snapshot = helper.snapshot([source])
        let tools = MCPWorkspaceTools(store: MCPWorkspaceStore(), capture: { _, _ in snapshot })
        let opened = await tools.execute(.init(name: "app_knowledge", arguments: [
            "action": "begin", "query": "Summarize this", "request_id": .string(UUID().uuidString),
            "scope": ["source_ids": [.string(source.id.uuidString)]]
        ]))
        #expect(opened.isError != true)
        let provider: Value = ["server": "voxstudio", "backend": "local_mcp", "tool": "app_evidence"]
        #expect(opened.structuredContent?.objectValue?["evidence_provider"] == provider)
        let next = try #require(opened.structuredContent?.objectValue?["next_call"]?.objectValue)
        #expect(next["tool"] == "app_evidence")
        let arguments = try #require(next["arguments"]?.objectValue)
        #expect(arguments["action"] == "fetch")
        #expect(arguments["source_id"] == .string(source.id.uuidString))
        let fetched = await tools.execute(.init(name: "app_evidence", arguments: arguments))
        #expect(fetched.isError != true)
        #expect(fetched.structuredContent?.objectValue?["evidence_provider"] == provider)
        let rows = try #require(fetched.structuredContent?.objectValue?["segments"]?.arrayValue)
        #expect(rows.first?.objectValue?["text"]?.stringValue?.contains("Irving Finkel") == true)
        let evidence = try #require(rows.first?.objectValue?["evidence_id"])
        let observation = try #require(fetched.structuredContent?.objectValue?["observation_id"])
        let done = await tools.execute(.init(name: "app_evidence", arguments: [
            "action": "complete_turn", "workspace_id": try #require(arguments["workspace_id"]),
            "turn_id": try #require(arguments["turn_id"]), "outcome": "answered",
            "cited_evidence_ids": [evidence], "cited_observation_ids": [observation]
        ]))
        #expect(done.isError != true)
        #expect(done.structuredContent?.objectValue?["status"] == "answered")
        #expect(done.structuredContent?.objectValue?["cited_evidence_ids"] == [evidence])
        #expect(done.structuredContent?.objectValue?["evidence_provider"] == provider)
    }
    @Test @MainActor func localEvidenceGatewayKeepsFrozenScopeAndRejectsActionSpecificArguments() async throws {
        let helper = KnowledgeEvidenceWorkspaceTests()
        let selected = helper.fixture(segments: [.init(text: "Authorized original", start: 0, end: 2)])
        let other = helper.fixture(segments: [.init(text: "Other original", start: 0, end: 2)])
        let snapshot = helper.snapshot([selected, other])
        let tools = MCPWorkspaceTools(store: MCPWorkspaceStore(), capture: { scope, _ in
            if scope == .all { return snapshot }
            return helper.snapshot(snapshot.sessions.filter { scope.sessionIDs.contains($0.id) })
        })
        let opened = await tools.execute(.init(name: "app_knowledge", arguments: [
            "action": "begin", "query": "Summarize this", "request_id": .string(UUID().uuidString),
            "scope": ["source_ids": [.string(selected.id.uuidString)]]
        ]))
        let workspace = try #require(opened.structuredContent?.objectValue?["workspace_id"])
        let turn = try #require(opened.structuredContent?.objectValue?["turn_id"])
        let forbidden = await tools.execute(.init(name: "app_evidence", arguments: [
            "action": "fetch", "workspace_id": workspace, "turn_id": turn, "source_id": .string(other.id.uuidString)
        ]))
        #expect(forbidden.isError == true)
        #expect(forbidden.structuredContent?.objectValue?["segments"] == nil)
        let listed = await tools.execute(.init(name: "app_evidence", arguments: [
            "action": "list_sources", "workspace_id": workspace, "turn_id": turn
        ]))
        #expect(listed.isError != true)
        #expect(listed.structuredContent?.objectValue?["sources"]?.arrayValue?.count == 1)
        #expect(listed.structuredContent?.objectValue?["sources"]?.arrayValue?.first?.objectValue?["source_id"] == .string(selected.id.uuidString))
        for arguments: [String: Value] in [
            ["action": "fetch", "source_id": .string(selected.id.uuidString), "request_id": .string(UUID().uuidString)],
            ["action": "list_sources", "query": "unexpected"],
            ["action": "complete_turn", "workspace_id": workspace, "turn_id": turn, "outcome": "answered", "source_id": .string(selected.id.uuidString)],
            ["action": "begin", "query": "question", "request_id": .string(UUID().uuidString), "source_id": .string(selected.id.uuidString)],
            ["action": "fetch", "workspace_id": workspace, "source_id": .string(selected.id.uuidString)]
        ] {
            let result = await tools.execute(.init(name: "app_evidence", arguments: arguments))
            #expect(result.isError == true)
            #expect(result.structuredContent?.objectValue?["segments"] == nil)
        }
    }
    @Test @MainActor func localEvidenceGatewayPaginationStaysOnTheLocalProvider() async throws {
        let helper = KnowledgeEvidenceWorkspaceTests()
        let snapshot = helper.snapshot([helper.fixture(title: "One"), helper.fixture(title: "Two")])
        let tools = MCPWorkspaceTools(store: MCPWorkspaceStore(), capture: { _, _ in snapshot })
        let opened = await tools.execute(.init(name: "app_knowledge", arguments: [
            "action": "begin", "query": "List the sessions", "request_id": .string(UUID().uuidString)
        ]))
        let search = try #require(opened.structuredContent?.objectValue?["next_call"]?.objectValue?["arguments"]?.objectValue)
        #expect(search["action"] == "search")
        let first = await tools.execute(.init(name: "app_evidence", arguments: [
            "action": "list_sources", "workspace_id": try #require(search["workspace_id"]),
            "turn_id": try #require(search["turn_id"]), "limit": 1
        ]))
        let next = try #require(first.structuredContent?.objectValue?["next_call"]?.objectValue)
        #expect(next["tool"] == "app_evidence")
        let arguments = try #require(next["arguments"]?.objectValue)
        #expect(arguments["action"] == "list_sources")
        #expect(arguments["workspace_id"] == search["workspace_id"])
        #expect(arguments["turn_id"] == search["turn_id"])
        let second = await tools.execute(.init(name: "app_evidence", arguments: arguments))
        #expect(second.isError != true)
        #expect(second.structuredContent?.objectValue?["complete"] == true)
        #expect(second.structuredContent?.objectValue?["next_call"] == nil)
        #expect(second.structuredContent?.objectValue?["sources"]?.arrayValue?.first != first.structuredContent?.objectValue?["sources"]?.arrayValue?.first)
    }
    @Test @MainActor func broadBeginDoesNotTurnPinnedReadingFocusIntoEvidenceScope() async throws {
        let snapshot = fixture()
        let tools = MCPWorkspaceTools(store: MCPWorkspaceStore(), capture: { _, _ in snapshot })
        let focused = await tools.execute(.init(name: "app_session", arguments: ["session_id": .string(snapshot.sessions[0].id.uuidString)]))
        let workspace = try #require(focused.structuredContent?.objectValue?["workspace_id"])
        let viewRevision = try #require(focused.structuredContent?.objectValue?["view_revision"])
        _ = await tools.execute(.init(name: "knowledge.update_view", arguments: [
            "workspace_id": workspace, "expected_view_revision": viewRevision, "view": ["pinned": true]
        ]))
        for scope: Value in [.object([:]), ["source_ids": .array(snapshot.sessions.map { .string($0.id.uuidString) })]] {
            let opened = await tools.execute(.init(name: "app_knowledge", arguments: [
                "action": "begin", "workspace_id": workspace, "query": "Compare the sessions",
                "request_id": .string(UUID().uuidString), "scope": scope
            ]))
            #expect(opened.isError != true)
            #expect(opened.structuredContent?.objectValue?["view"]?.objectValue?["source_id"] == .string(snapshot.sessions[0].id.uuidString))
            let next = try #require(opened.structuredContent?.objectValue?["next_call"]?.objectValue?["arguments"]?.objectValue)
            #expect(next["action"] == "search")
            #expect(next["source_id"] == nil)
            #expect(opened.structuredContent?.objectValue?["scope"] == scope)
        }
    }
    @Test @MainActor func frozenCatalogCanPageInItsOriginalScopeWithoutChangingTheCompletedTurn() async throws {
        let helper=KnowledgeEvidenceWorkspaceTests()
        let snapshot=helper.snapshot([helper.fixture(title:"One"),helper.fixture(title:"Two"),helper.fixture(title:"Unrelated")])
        let tools=MCPWorkspaceTools(store:MCPWorkspaceStore(),capture:{scope,_ in
            if scope == .all {return snapshot}
            let sources=snapshot.sessions.filter{scope.sessionIDs.contains($0.id)}
            return KnowledgeScopeSnapshot(scope:scope,ownerID:snapshot.ownerID,sessions:sources,generations:snapshot.generations,isLive:false)
        })
        let selected=snapshot.sessions.prefix(2).map{Value.string($0.id.uuidString)}
        let opened=await tools.execute(.init(name:"app_knowledge",arguments:["action":"begin","query":"List these sessions","request_id":.string(UUID().uuidString),"scope":["source_ids":.array(selected)]]))
        let id=try #require(opened.structuredContent?.objectValue?["workspace_id"]),turn=try #require(opened.structuredContent?.objectValue?["turn_id"])
        let first=await tools.execute(.init(name:"list_sources",arguments:["workspace_id":id,"turn_id":turn,"limit":1]))
        let observation=try #require(first.structuredContent?.objectValue?["observation_id"])
        let cursor=try #require(first.structuredContent?.objectValue?["next_cursor"])
        let done=await tools.execute(.init(name:"knowledge.complete_turn",arguments:["workspace_id":id,"turn_id":turn,"outcome":"answered","cited_observation_ids":[observation]]))
        let page=await tools.execute(.init(name:"knowledge.workspace_state",arguments:["workspace_id":id,"turn_id":turn,"page":["observation_id":observation,"cursor":cursor]]))
        #expect(page.isError != true)
        let rows=try #require(page.structuredContent?.objectValue?["page"]?.objectValue?["sources"]?.arrayValue)
        #expect(rows.count==1)
        #expect(rows[0].objectValue?["title"]?.stringValue != "Unrelated")
        #expect(rows[0].objectValue?["source_id"] != first.structuredContent?.objectValue?["sources"]?.arrayValue?.first?.objectValue?["source_id"])
        let after=await tools.execute(.init(name:"knowledge.workspace_state",arguments:["workspace_id":id,"turn_id":turn]))
        #expect(after.structuredContent==done.structuredContent)
    }
    @Test @MainActor func writeReceiptsExecuteConcurrentRetriesOnceAndRejectConflicts() async throws {
        let snapshot=fixture(),receipts=MCPMutationReceipts(capture:{snapshot})
        let count=WriteCount()
        let request=UUID().uuidString
        let parameters=CallTool.Parameters(name:"test.write",arguments:["request_id":.string(request),"value":1])
        async let first=receipts.execute(parameters) { count.value+=1;await Task.yield();return MCPWorkspaceTools.result(["success":true]) }
        async let second=receipts.execute(parameters) { count.value+=1;return MCPWorkspaceTools.result(["success":false]) }
        let (a,b)=await (first,second)
        #expect(a==b);#expect(count.value==1)
        let bad=await receipts.execute(.init(name:"test.write",arguments:["request_id":.string(request),"value":2])) { count.value+=1;return .init() }
        #expect(bad.isError==true);#expect(count.value==1)
    }
    @Test @MainActor func reconnectReceiptsRecoverOnlyReturnedJobsAndDocumentGrants() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let input=root.appendingPathComponent("selected.txt");try Data("Selected public test text".utf8).write(to:input)
        let documents=MCPDocumentStore(root:root.appendingPathComponent("documents"))
        let server=Server(name:"test",version:"1",capabilities:.init())
        let old=MCPOpenAIExtensions(server:server,documentStore:documents,fileChooser:{_ in input})
        old.initialize(.init(extensions:["openai/elicitation":["form":.object([:])]]))
        let next=MCPOpenAIExtensions(server:server,documentStore:documents)
        let unrelated=MCPOpenAIExtensions(server:server,documentStore:documents)
        let snapshot=fixture(),receipts=MCPMutationReceipts(capture:{snapshot})
        let params=CallTool.Parameters(name:"documents.choose_local_file",arguments:["request_id":.string(UUID().uuidString)])
        let initial=await receipts.execute(params,context:old) { await old.execute(.init(name:params.name,arguments:[:])) }
        let retried=await receipts.execute(params,context:next) { Issue.record("Replayed picker");return .init() }
        #expect(initial==retried);#expect(old.supportsForm);#expect(!next.supportsForm)
        let job=try #require(initial.structuredContent?.objectValue?["job_id"])
        var resolved=await next.execute(.init(name:"voxstudio.job_status",arguments:["job_id":job]))
        for _ in 0..<100 where resolved.structuredContent?.objectValue?["document_id"]==nil {
            try await Task.sleep(for:.milliseconds(5))
            resolved=await next.execute(.init(name:"voxstudio.job_status",arguments:["job_id":job]))
        }
        let id=try #require(resolved.structuredContent?.objectValue?["document_id"])
        let read=await next.execute(.init(name:"documents.read",arguments:["document_id":id]))
        #expect(read.isError != true)
        #expect(read.structuredContent?.objectValue?["text"]=="Selected public test text")
        let denied=await unrelated.execute(.init(name:"documents.read",arguments:["document_id":id]))
        #expect(denied.isError==true)
        let uri=try #require(read.structuredContent?.objectValue?["resource_uri"]?.stringValue)
        let resource=try await next.readResource(uri)
        #expect(resource.contents.count==1)
        let privateCopy=await old.execute(.init(name:"documents.import_text",arguments:["name":"other.txt","blob":.string(Data("Unrelated document".utf8).base64EncodedString())]))
        let privateID=try #require(privateCopy.structuredContent?.objectValue?["document_id"])
        #expect(await next.execute(.init(name:"documents.read",arguments:["document_id":privateID])).isError==true)
    }

}
