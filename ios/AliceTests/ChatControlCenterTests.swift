import XCTest
@testable import Alice

final class ChatControlCenterTests: XCTestCase {
    func testBareReadCommandsUseNativeControlCenter() {
        XCTAssertEqual(ChatControlCenter.parse("/agents"), .bots)
        XCTAssertEqual(ChatControlCenter.parse("/bots"), .bots)
        XCTAssertEqual(ChatControlCenter.parse("/projects"), .projects(profile: nil))
        XCTAssertEqual(ChatControlCenter.parse("/memory --profile radar-ia"), .memory(profile: "radar-ia"))
        XCTAssertEqual(ChatControlCenter.parse("/usage 90"), .usage(profile: nil, days: 90))
    }

    func testQuotedProjectCreationPreservesNameAndFolder() {
        XCTAssertEqual(
            ChatControlCenter.parse(#"/project create "Alice iOS" --folder "/Users/me/Alice App" --profile default"#),
            .projectCreate(name: "Alice iOS", folder: "/Users/me/Alice App", profile: "default")
        )
    }

    func testModelMutationRequiresExplicitGrammarAndCarriesConfirmation() {
        XCTAssertEqual(
            ChatControlCenter.parse("/model set xai-oauth grok-4.6 --confirm --profile radar-ia"),
            .modelSet(provider: "xai-oauth", model: "grok-4.6", profile: "radar-ia", confirm: true)
        )
        XCTAssertNil(ChatControlCenter.parse("/model grok-4.6"))
    }

    func testDestructiveProviderDisconnectCarriesExplicitConfirmation() {
        XCTAssertEqual(
            ChatControlCenter.parse("/provider disconnect openai-codex --confirm"),
            .providerDisconnect(identifier: "openai-codex", profile: nil, confirm: true)
        )
    }

    func testMemoryAddKeepsSpacesAndTarget() {
        XCTAssertEqual(
            ChatControlCenter.parse(#"/memory add user "Prefiere respuestas concisas" --profile default"#),
            .memoryAdd(target: "user", text: "Prefiere respuestas concisas", profile: "default")
        )
    }

    func testConfigMutationIsCuratedSyntax() {
        XCTAssertEqual(
            ChatControlCenter.parse("/config set compression-threshold 65% --profile default"),
            .configSet(key: "compression-threshold", value: "65%", profile: "default")
        )
        XCTAssertNil(ChatControlCenter.parse("/config raw model.api_key secret"))
    }

    func testUnknownSlashCommandsStillBelongToHermes() {
        XCTAssertNil(ChatControlCenter.parse("/status"))
        XCTAssertNil(ChatControlCenter.parse("/tools"))
        XCTAssertNil(ChatControlCenter.parse("/memory search cats"))
        XCTAssertNil(ChatControlCenter.parse("/reasoning"))
        XCTAssertNil(ChatControlCenter.parse("/reasoning medium"))
        XCTAssertTrue(Slash.looksLikeCommand("/reasoning"))
        XCTAssertTrue(Slash.looksLikeCommand("/reasoning medium"))
        XCTAssertTrue(Slash.looksLikeCommand("/status"))
        XCTAssertFalse(Slash.looksLikeCommand("/usr/local"))
        XCTAssertFalse(Slash.looksLikeCommand("hola /reasoning"))
        XCTAssertTrue(Slash.isLocalNewChat("/new"))
        XCTAssertTrue(Slash.isLocalNewChat("/reset"))
        XCTAssertFalse(Slash.isLocalNewChat("/reasoning"))
    }

    func testDebugIsAnAliceControlCommand() {
        XCTAssertEqual(ChatControlCenter.parse("/debug"), .debug)
        XCTAssertNil(ChatControlCenter.parse("/debug extra"))
    }

    func testNaturalReadsAreNarrowAndAccentInsensitive() {
        XCTAssertEqual(ChatControlCenter.parse("¿Qué bots tengo?"), .bots)
        XCTAssertEqual(ChatControlCenter.parse("Muéstrame mis proyectos"), .projects(profile: nil))
        XCTAssertEqual(ChatControlCenter.parse("qué modelo estoy usando?"), .model(profile: nil))
        XCTAssertNil(ChatControlCenter.parse("cambia mi modelo al más rápido"))
    }

    func testTokenizerDoesNotSplitQuotedArguments() {
        XCTAssertEqual(
            ChatControlCenter.tokenize(#"/project create "Mi Proyecto" --folder '/tmp/with space'"#),
            ["/project", "create", "Mi Proyecto", "--folder", "/tmp/with space"]
        )
    }

    func testProviderKeyMaterialIsNeverAcceptedAsAChatControlCommand() {
        XCTAssertNil(ChatControlCenter.parse("/provider key OPENAI_API_KEY sk-secret"))
    }
    func testDestructiveAndCreateMutationsHaveExplicitShapes() {
        XCTAssertEqual(
            ChatControlCenter.parse(#"/bot rename radar-ia --to "Radar IA Pro""#),
            .botRename(identifier: "radar-ia", title: "Radar IA Pro")
        )
        XCTAssertEqual(
            ChatControlCenter.parse("/bot delete radar-ia --confirm"),
            .botDelete(identifier: "radar-ia", confirm: true)
        )
        XCTAssertEqual(
            ChatControlCenter.parse(#"/routine create "Morning Brief" --schedule "0 9 * * *" --prompt "Summarize overnight" --profile default"#),
            .routineCreate(
                name: "Morning Brief", prompt: "Summarize overnight",
                schedule: "0 9 * * *", deliver: "local", profile: "default"
            )
        )
        XCTAssertEqual(
            ChatControlCenter.parse("/project archive Alice --profile default"),
            .projectArchive(identifier: "Alice", archived: true, profile: "default")
        )
    }

    func testMemoryReplaceAndRemoveStayExact() {
        XCTAssertEqual(
            ChatControlCenter.parse(#"/memory replace user --old "old fact" --new "new fact""#),
            .memoryReplace(target: "user", oldText: "old fact", newText: "new fact", profile: nil)
        )
        XCTAssertEqual(
            ChatControlCenter.parse(#"/memory remove memory "stale fact" --confirm"#),
            .memoryRemove(target: "memory", text: "stale fact", profile: nil, confirm: true)
        )
    }

    func testNaturalSafeMutationsMapToNativeActions() {
        XCTAssertEqual(
            ChatControlCenter.parse("abre el bot Radar IA"),
            .botOpen(identifier: "Radar IA")
        )
        XCTAssertEqual(
            ChatControlCenter.parse("pausa la rutina Morning Brief"),
            .routine(action: "pause", identifier: "Morning Brief", profile: nil)
        )
        XCTAssertEqual(
            ChatControlCenter.parse("activa el proyecto Alice iOS"),
            .projectUse(identifier: "Alice iOS", profile: nil)
        )
        XCTAssertEqual(
            ChatControlCenter.parse("recuerda que prefiero respuestas breves"),
            .memoryAdd(target: "memory", text: "prefiero respuestas breves", profile: nil)
        )
        XCTAssertEqual(
            ChatControlCenter.parse("recuerda que Prefiero café y Respuestas Breves"),
            .memoryAdd(target: "memory", text: "Prefiero café y Respuestas Breves", profile: nil)
        )
        XCTAssertEqual(
            ChatControlCenter.parse("cambia el modelo a grok-4.6 con xai-oauth"),
            .modelSet(provider: "xai-oauth", model: "grok-4.6", profile: nil, confirm: false)
        )
    }

    func testReasoningUsageBecomesASentenceAndTappableLevels() {
        let presented = SlashReply.present(
            command: "/reasoning",
            output: """
            Reasoning effort: low
            Reasoning display: off (clamped to 10 lines)
            Usage: /reasoning <none|minimal|low|medium|high|xhigh|max|ultra|show|hide|full|clamp> [--global]
            """
        )
        XCTAssertFalse(presented.text.localizedCaseInsensitiveContains("usage:"))
        XCTAssertFalse(presented.text.contains("|"))
        XCTAssertTrue(presented.text.contains("thinks briefly"))
        XCTAssertTrue(presented.text.contains("don't see that thinking"))
        XCTAssertEqual(
            presented.choices.first { $0.command == "/reasoning low" }?.current, true
        )
        XCTAssertEqual(
            presented.choices.first { $0.command == "/reasoning hide" }?.current, true
        )
        XCTAssertEqual(
            presented.choices.first { $0.command == "/reasoning clamp" }?.current, true
        )
        XCTAssertNil(presented.choices.first { $0.command.contains("status") })
        XCTAssertEqual(
            presented.choices.first { $0.command == "/reasoning medium" }?.label, "Medium"
        )
    }

    func testASettingChangeConfirmsInPlainLanguage() {
        let presented = SlashReply.present(
            command: "/reasoning medium",
            output: "✓ Reasoning effort set to 'medium' (this session only)"
        )
        XCTAssertTrue(presented.text.contains("normal amount"))
        XCTAssertTrue(presented.text.contains("This chat only."))
        XCTAssertFalse(presented.text.contains("set to"))
    }

    func testAnyCommandWithAPipeMenuBecomesChoices() {
        let presented = SlashReply.present(
            command: "/busy",
            output: """
            Busy input mode: interrupt
            Usage: /busy [queue|steer|interrupt|status]
            """
        )
        XCTAssertFalse(presented.text.localizedCaseInsensitiveContains("usage:"))
        XCTAssertEqual(presented.choices.map(\.command), [
            "/busy queue", "/busy steer", "/busy interrupt",
        ])
        XCTAssertEqual(presented.choices.first { $0.command == "/busy interrupt" }?.current, true)
    }

    func testAConfirmCommandBecomesAButtonAndATemplateDoesNot() {
        let presented = SlashReply.present(
            command: "/bot delete radar",
            output: "Deleting **Radar** removes its Hermes profile. Run `/bot delete radar --confirm` to confirm."
        )
        XCTAssertEqual(presented.choices.map(\.label), ["Confirm"])
        XCTAssertEqual(presented.choices.first?.command, "/bot delete radar --confirm")
        XCTAssertFalse(presented.text.localizedCaseInsensitiveContains("confirm"))
        XCTAssertTrue(presented.text.contains("Radar"))

        let template = SlashReply.present(
            command: "/model",
            output: "Switch with `/model set <provider> <model>`."
        )
        XCTAssertTrue(template.choices.isEmpty)
    }

    func testPersonalityRosterBecomesTones() {
        let presented = SlashReply.present(
            command: "/personality",
            output: """
            +--------------------------------------------------+
            |            (^o^)/ Personalities                 |
            +--------------------------------------------------+

               none         - (no personality overlay)
             * helpful      - warm and direct
               concise      - short answers
              Usage: /personality <name>   (* = active)
            """
        )
        XCTAssertTrue(presented.text.contains("Helpful"))
        XCTAssertFalse(presented.text.contains("Usage:"))
        XCTAssertFalse(presented.text.contains("+--"))
        XCTAssertEqual(presented.choices.map(\.command), [
            "/personality none", "/personality helpful", "/personality concise",
        ])
        XCTAssertEqual(presented.choices.first { $0.current }?.command, "/personality helpful")
    }

    func testASavedModelCatalogueOpensThePickerInsteadOfAButtonWall() {
        var message = Message(id: "m", role: .assistant, content: "Grok is answering.", createdAt: Date())
        message.slashChoices = [
            SlashChoice(label: "Grok 4.7", command: "/model set xai-oauth grok-4.7", current: true),
            SlashChoice(label: "Grok 4.6", command: "/model set xai-oauth grok-4.6", current: false),
        ]
        XCTAssertTrue(message.choosesModelInAPicker)

        message.slashChoices = [
            SlashChoice(label: "Low", command: "/reasoning low", current: true),
            SlashChoice(label: "Medium", command: "/reasoning medium", current: false),
        ]
        XCTAssertFalse(message.choosesModelInAPicker)
    }

    func testAgentListBecomesOpenButtons() {
        let presented = SlashReply.present(
            command: "/agents",
            output: """
            **Bots**

            - **Radar** (`radar`) — xai / grok
            - **Inbox** (`inbox`)

            Use `/bot open <name>` or `/bot create <name>`.
            """
        )
        XCTAssertEqual(presented.choices.map(\.label), ["Open Radar", "Open Inbox"])
        XCTAssertEqual(presented.choices.map(\.command), ["/bot open radar", "/bot open inbox"])
        XCTAssertFalse(presented.text.contains("<name>"))
        XCTAssertFalse(presented.text.contains("radar"))
    }

    func testAnOldMessageWithoutChoicesStillDecodes() throws {
        let json = """
        {"id":"m1","role":"assistant","content":"Hola","createdAt":0}
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(message.content, "Hola")
        XCTAssertTrue(message.slashChoices.isEmpty)
    }

}
