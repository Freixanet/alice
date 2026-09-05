import XCTest
@testable import Alice

final class HermesSelfUpdateIntentTests: XCTestCase {
    func testExplicitUpdateCommandsAreRecognized() {
        for command in [
            "/update",
            "actualízate",
            "actualízate a la última versión",
            "actualiza Hermes",
            "Por favor, actualiza Hermes a la última versión",
            "¿Puedes actualizar Hermes?",
            "update Hermes",
            "upgrade Hermes agent",
            "instala la última actualización de Hermes",
        ] {
            XCTAssertTrue(
                HermesSelfUpdateIntent.matches(command),
                "Expected self-update intent for: \(command)"
            )
        }
    }

    func testQuestionsAndTroubleshootingDoNotTriggerUpdate() {
        for text in [
            "¿Cómo actualizo Hermes?",
            "¿Hay una actualización de Hermes?",
            "¿Por qué falló la actualización de Hermes?",
            "Explícame cómo funciona hermes update",
            "No actualices Hermes",
            "actualiza el proyecto Hermes",
            "puedes decirme si Hermes está actualizado",
            "update",
        ] {
            XCTAssertFalse(
                HermesSelfUpdateIntent.matches(text),
                "Unexpected self-update intent for: \(text)"
            )
        }
    }
}
