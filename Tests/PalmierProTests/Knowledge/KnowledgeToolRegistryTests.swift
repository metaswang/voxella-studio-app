import Testing
import Foundation
@testable import PalmierPro

/// Test knowledge tool registry and allowlist
struct KnowledgeToolRegistryTests {
    @Test("All built-in tools are registered")
    func testAllToolsRegistered() {
        let allTools = KnowledgeToolRegistry.allTools
        #expect(allTools.count >= 10)
        
        let names = Set(allTools.map(\.name))
        #expect(names.contains("knowledge.search"))
        #expect(names.contains("session.list"))
        #expect(!names.contains("finish_with_evidence"))
        #expect(names.contains("analysis.update"))
        #expect(names.contains("ask_clarification"))
    }
    
    @Test("Tool allowlist validation")
    func testToolAllowlist() {
        #expect(KnowledgeToolRegistry.isAllowed("knowledge.search"))
        #expect(KnowledgeToolRegistry.isAllowed("session.list"))
        #expect(!KnowledgeToolRegistry.isAllowed("unknown_tool"))
        #expect(!KnowledgeToolRegistry.isAllowed(""))
    }
    
    @Test("Tool lookup by name")
    func testToolLookup() {
        let searchTool = KnowledgeToolRegistry.tool(named: "knowledge.search")
        #expect(searchTool != nil)
        #expect(searchTool?.description.contains("graph recall") == true)
        #expect(!searchTool!.parameters.isEmpty)
        
        let unknownTool = KnowledgeToolRegistry.tool(named: "nonexistent")
        #expect(unknownTool == nil)
    }
    
    @Test("Skill validation with allowed tools")
    func testSkillValidation() {
        let validSkill = Skill(
            id: "test_valid",
            name: "Valid Skill",
            description: "Test skill",
            path: URL(fileURLWithPath: "/tmp/test.md"),
            category: "knowledge",
            metadata: KnowledgeSkillMetadata(
                allowedTools: ["knowledge.search", "session.list"]
            )
        )
        #expect(KnowledgeToolRegistry.validateSkill(validSkill))
        
        let invalidSkill = Skill(
            id: "test_invalid",
            name: "Invalid Skill",
            description: "Test skill",
            path: URL(fileURLWithPath: "/tmp/test.md"),
            category: "knowledge",
            metadata: KnowledgeSkillMetadata(
                allowedTools: ["knowledge.search", "unknown_tool"]
            )
        )
        #expect(!KnowledgeToolRegistry.validateSkill(invalidSkill))
    }
}
