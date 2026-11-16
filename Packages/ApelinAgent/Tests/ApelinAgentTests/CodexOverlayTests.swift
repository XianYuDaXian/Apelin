@testable import ApelinAgent
import Foundation
import Testing

/// 验证移植的 Codex 叠加层只注入一次，且不替换 Apelin 自带规则、技能目录仍保持在末尾。
@Suite("Codex 交付叠加层")
struct CodexOverlayTests {
    @Test
    func `叠加层只出现一次且保留内置提示词`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }

        let prompt = SystemPrompt.make(
            project: home.project,
            projectRoot: home.projectURL.path,
            skills: BuiltInSkills.all,
            mcpServers: [],
        )

        #expect(prompt.components(separatedBy: CodexOverlay.marker).count == 2)
        #expect(prompt.contains("You are the agent inside Apelin"))
        #expect(prompt.contains("Every visible assistant reply begins with `[P]`"))
        #expect(prompt.contains("Task routing"))
        #expect(prompt.contains("Prescriptive templates"))
        #expect(prompt.contains("CONTINUATION"))
        #expect(prompt.contains("Approval modes"), "审批规则仍在")
        #expect(prompt.hasSuffix("</available_skills>"), "技能目录保持在提示词末尾")
        #expect(prompt.range(of: CodexOverlay.marker)!.lowerBound < prompt.range(of: "# Skills")!.lowerBound)
    }

    @Test
    func `关闭叠加层后系统提示词不再包含Codex段落`() throws {
        let previous = CodexOverlay.enabled
        defer { CodexOverlay.enabled = previous }
        CodexOverlay.enabled = false
        let home = try TemporaryHome()
        defer { home.remove() }

        let prompt = SystemPrompt.make(
            project: home.project,
            projectRoot: home.projectURL.path,
            skills: BuiltInSkills.all,
            mcpServers: [],
        )

        #expect(!prompt.contains(CodexOverlay.marker))
        #expect(prompt.contains("You are the agent inside Apelin"))
        #expect(prompt.contains("Approval modes"))
    }
}
