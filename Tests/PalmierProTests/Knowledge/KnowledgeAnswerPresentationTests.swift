import Testing
@testable import PalmierPro

struct KnowledgeAnswerPresentationTests {
    @Test
    func removesMachineCitationTokensFromAnswerProse() {
        let answer = """
        - 医疗相关的职业与角色
          - 提及中医师/医师等医学身份与职业的内容 45。
        - 健康问题与病症
          - 讨论背痛和腰椎盘突出等相关话题 123。
        - 治疗、康复与理论
          - 通过动作调整错位关节 235。
        - 人生经历/职业转折
          - 讲述转为中医师的故事 5。
        - 具体治疗动作
          - 重复20次，并引用 [1, 4]。
        """

        let displayed = KnowledgeAnswerPresentation.displayText(answer, citationCount: 5)

        #expect(!displayed.contains(" 45"))
        #expect(!displayed.contains(" 123"))
        #expect(!displayed.contains(" 235"))
        #expect(!displayed.contains(" 5"))
        #expect(!displayed.contains("[1, 4]"))
        #expect(displayed.contains("重复20次"))
        #expect(displayed.contains("相关话题。"))
    }

    @Test
    func preservesNumbersWhenThereIsNoEvidenceList() {
        let answer = "会议包含 1 个决定，预计 45 分钟。"

        #expect(KnowledgeAnswerPresentation.displayText(answer, citationCount: 0) == answer)
    }

    @Test
    func preservesNumbersAttachedToWords() {
        let answer = "动作重复20次，完成率为45%。"

        #expect(KnowledgeAnswerPresentation.displayText(answer, citationCount: 5) == answer)
    }

    @Test
    func removesCitationMarkersWhenPersistedSourceListIsMissing() {
        let answer = """
        - 医疗相关的职业与角色 45。
        - 健康问题与病症 123。
        - 治疗、康复与理论 235。
        """

        let displayed = KnowledgeAnswerPresentation.displayText(answer, citationCount: 0)
        #expect(!displayed.contains(" 45"))
        #expect(!displayed.contains(" 123"))
        #expect(!displayed.contains(" 235"))
        #expect(displayed.contains("健康问题与病症。"))
    }

    @Test
    func removesBracketedCitationMarkersWhenPersistedSourceListIsMissing() {
        let answer = "医疗相关的职业与角色 [2][5]。"

        let displayed = KnowledgeAnswerPresentation.displayText(answer, citationCount: 0)
        #expect(displayed == "医疗相关的职业与角色。")
    }
}
