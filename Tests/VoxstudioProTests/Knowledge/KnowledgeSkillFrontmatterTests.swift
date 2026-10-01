import Testing
import Foundation
@testable import VoxstudioPro

/// Test skill frontmatter parsing with KB extension fields
struct KnowledgeSkillFrontmatterTests {
    @Test("Parse simple skill frontmatter")
    func testSimpleFrontmatter() {
        let text = """
        ---
        name: Test Skill
        description: A test skill
        ---
        
        # Body content
        """
        
        let (fields, lists, body) = SkillFrontmatter.parse(text)
        
        #expect(fields["name"] == "Test Skill")
        #expect(fields["description"] == "A test skill")
        #expect(lists.isEmpty)
        #expect(body.hasPrefix("# Body content"))
    }
    
    @Test("Parse KB skill with lists")
    func testKBSkillWithLists() {
        let text = """
        ---
        name: Content QA
        description: Answer questions
        category: knowledge
        allowed_tools:
          - knowledge.search
          - session.search_segments
        supports_evidence_goals:
          - semantic_qa
          - fact_extraction
        ---
        
        Body text
        """
        
        let (fields, lists, body) = SkillFrontmatter.parse(text)
        
        #expect(fields["name"] == "Content QA")
        #expect(fields["category"] == "knowledge")
        #expect(lists["allowed_tools"] == ["knowledge.search", "session.search_segments"])
        #expect(lists["supports_evidence_goals"] == ["semantic_qa", "fact_extraction"])
        #expect(body == "Body text")
    }
    
    @Test("Parse requiredFields with KB metadata")
    func testRequiredFieldsWithMetadata() {
        let text = """
        ---
        name: Timeline QA
        description: Time-based queries
        category: knowledge
        selection_summary: Time-based conditional queries
        applies_when: User asks about time ranges
        allowed_tools:
          - session.get_timeline
          - session.search_segments
        ---
        
        Content
        """
        
        guard let parsed = SkillFrontmatter.requiredFields(text) else {
            Issue.record("Failed to parse required fields")
            return
        }
        
        #expect(parsed.name == "Timeline QA")
        #expect(parsed.description == "Time-based queries")
        #expect(parsed.category == "knowledge")
        #expect(parsed.metadata != nil)
        #expect(parsed.metadata?.selectionSummary == "Time-based conditional queries")
        #expect(parsed.metadata?.appliesWhen == "User asks about time ranges")
        #expect(parsed.metadata?.allowedTools.count == 2)
    }
    
    @Test("Non-KB skill has no metadata")
    func testNonKBSkill() {
        let text = """
        ---
        name: Video Edit
        description: Edit videos
        category: video-editing
        ---
        
        Body
        """
        
        guard let parsed = SkillFrontmatter.requiredFields(text) else {
            Issue.record("Failed to parse")
            return
        }
        
        #expect(parsed.category == "video-editing")
        #expect(parsed.metadata == nil)
    }
}
