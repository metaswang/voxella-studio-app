import Foundation
import Testing
@testable import VoxstudioPro

struct SkillCatalogTests {
    @Test func decodesCategoryFromCatalog() throws {
        let data = Data(#"[{"id":"captions","category":"video-editing","name":"Captions","description":"Style captions.","sha":"abc123","path":"skills/video-editing/captions/SKILL.md"}]"#.utf8)

        let entry = try #require(JSONDecoder().decode([SkillCatalogEntry].self, from: data).first)

        #expect(entry.skillCategory == .videoEditing)
        #expect(entry.skillCategory.title == "Video Editing")
    }

    @Test func legacyCatalogEntryFallsBackToOtherCategory() throws {
        let data = Data(#"[{"id":"legacy","name":"Legacy","description":"Legacy skill.","sha":"abc123","path":"skills/legacy/SKILL.md"}]"#.utf8)

        let entry = try #require(JSONDecoder().decode([SkillCatalogEntry].self, from: data).first)

        #expect(entry.skillCategory.id == "other")
        #expect(entry.skillCategory.title == "Other")
    }

    @Test func usesVoxStudioSkillsRepositoryByDefault() {
        #expect(SkillCatalog.defaultBase == "https://raw.githubusercontent.com/voxstudio-me/voxstudio-skills/main")
    }
}
