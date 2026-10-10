import Foundation
import A2UISwiftCore
import A2UISwiftUI

/// Only fixed, bundled demo data is accepted here; no model-authored payloads.
enum A2UIGallerySample: String, CaseIterable, Identifiable {
    case text, inputs, choices, date, layouts, tabs, modal, media
    var id: String { rawValue }
    var title: String {
        switch self {
        case .text: "Texto, iconos e imagen"
        case .inputs: "Campos, casilla, deslizador y botón"
        case .choices: "Opciones y selección múltiple"
        case .date: "Fecha y hora"
        case .layouts: "Tarjeta, filas, columnas y lista"
        case .tabs: "Pestañas"
        case .modal: "Ventana emergente"
        case .media: "Audio y vídeo"
        }
    }
    var detail: String {
        switch self {
        case .text: "Text · Icon · Image (imagen local de ejemplo)"
        case .inputs: "TextField · CheckBox · Slider · Button"
        case .choices: "ChoicePicker: una opción o varias"
        case .date: "DateTimeInput: fecha, hora y ambas"
        case .layouts: "Card · Row · Column · List · Divider"
        case .tabs: "Tabs: cambia entre Resumen y Detalles"
        case .modal: "Modal: abre una hoja sin salir de la galería"
        case .media: "AudioPlayer · Video: archivos de prueba locales"
        }
    }
    private var components: [[String: Any]] {
        func node(_ id: String, _ type: String, _ props: [String: Any] = [:]) -> [String: Any] {
            props.merging(["id": id, "component": type]) { _, new in new }
        }
        func text(_ id: String, _ value: String, _ variant: String = "body") -> [String: Any] {
            node(id, "Text", ["text": value, "variant": variant])
        }
        switch self {
        case .text:
            return [node("root", "Column", ["children": ["title", "body", "icon", "image"]]),
                    text("title", "Un día con Alice", "h2"), text("body", "Todo preparado para tu próxima aventura."),
                    node("icon", "Icon", ["name": "favorite"]),
                    node("image", "Image", ["url": "local-sun", "variant": "smallFeature", "fit": "contain"])]
        case .inputs:
            return [node("root", "Column", ["children": ["name", "note", "check", "slider", "button"]]),
                    node("name", "TextField", ["label": "Tu nombre", "value": ["path": "/name"]]),
                    node("note", "TextField", ["label": "Una nota", "variant": "longText", "value": ["path": "/note"]]),
                    node("check", "CheckBox", ["label": "Recordármelo", "value": ["path": "/checked"]]),
                    node("slider", "Slider", ["label": "Prioridad", "value": ["path": "/priority"], "min": 0, "max": 100]),
                    node("button", "Button", ["child": "label", "action": ["event": ["name": "probar"]]]), text("label", "Probar botón")]
        case .choices:
            let options = [["label": "Mañana", "value": "morning"], ["label": "Tarde", "value": "afternoon"], ["label": "Noche", "value": "night"]]
            return [node("root", "Column", ["children": ["one", "many"]]),
                    node("one", "ChoicePicker", ["label": "¿Cuándo?", "value": ["path": "/one"], "variant": "mutuallyExclusive", "displayStyle": "chips", "options": options]),
                    node("many", "ChoicePicker", ["label": "Elige varias", "value": ["path": "/many"], "variant": "multipleSelection", "displayStyle": "checkbox", "filterable": true, "options": options])]
        case .date:
            return [node("root", "Column", ["children": ["date", "time", "both"]]),
                    node("date", "DateTimeInput", ["label": "Fecha", "value": ["path": "/date"], "enableDate": true, "enableTime": false]),
                    node("time", "DateTimeInput", ["label": "Hora", "value": ["path": "/time"], "enableDate": false, "enableTime": true]),
                    node("both", "DateTimeInput", ["label": "Fecha y hora", "value": ["path": "/both"], "enableDate": true, "enableTime": true])]
        case .layouts:
            return [node("root", "Card", ["child": "column"]), node("column", "Column", ["children": ["heading", "row", "divider", "list"]]),
                    text("heading", "Escapada de fin de semana", "h3"), node("row", "Row", ["children": ["where", "when"], "justify": "spaceBetween"]),
                    text("where", "Madrid"), text("when", "Sábado"), node("divider", "Divider"),
                    node("list", "List", ["children": ["a", "b"], "direction": "vertical"]), text("a", "Preparar mochila"), text("b", "Reservar mesa")]
        case .tabs:
            return [node("root", "Tabs", ["tabs": [["title": "Resumen", "child": "summary"], ["title": "Detalles", "child": "details"]]]),
                    text("summary", "Tres cosas para hoy."), text("details", "Pasear, preparar el viaje y llamar a casa.")]
        case .modal:
            return [node("root", "Modal", ["trigger": "open", "content": "content"]),
                    node("open", "Button", ["child": "openLabel", "action": ["event": ["name": "open_modal"]]]), text("openLabel", "Abrir ejemplo"),
                    node("content", "Column", ["children": ["body", "close"]]), text("body", "Esta es una ventana de ejemplo. No guarda ningún cambio."),
                    node("close", "Button", ["child": "closeLabel", "action": ["event": ["name": "dismiss_modal"]]]), text("closeLabel", "Cerrar")]
        case .media:
            return [node("root", "Column", ["children": ["audio", "video"]]),
                    node("audio", "AudioPlayer", ["url": mediaURL("a2ui-demo", "wav"), "description": "Tono de prueba · 2 segundos"]),
                    node("video", "Video", ["url": mediaURL("a2ui-demo", "mp4")])]
        }
    }
    private func mediaURL(_ name: String, _ ext: String) -> String {
        Bundle.main.url(forResource: name, withExtension: ext)?.absoluteString ?? ""
    }
    func makeModel() throws -> SurfaceViewModel {
        let payload: [[String: Any]] = [
            ["version": "v0.9", "createSurface": ["surfaceId": id, "catalogId": basicCatalogId]],
            ["version": "v0.9", "updateComponents": ["surfaceId": id, "components": components]],
            ["version": "v0.9", "updateDataModel": ["surfaceId": id, "value": [
                "name": "", "note": "", "checked": false, "priority": 50,
                "one": ["morning"], "many": ["morning", "night"],
                "date": "2026-10-10", "time": "08:00:00", "both": "2026-10-10T08:00:00"]]]
        ]
        let messages = try JSONDecoder().decode([A2uiMessage].self, from: JSONSerialization.data(withJSONObject: payload))
        let model = SurfaceViewModel(surface: SurfaceModel(id: id, catalog: basicCatalog))
        let errors = model.processMessages(messages)
        if let error = errors.first { throw error }
        guard model.componentTree != nil else { throw CocoaError(.coderInvalidValue) }
        return model
    }
}
