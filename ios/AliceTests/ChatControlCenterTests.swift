import XCTest
@testable import Alice

final class ChatControlCenterTests: XCTestCase {
    func testBareReadCommandsUseNativeControlCenter() {
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

}
