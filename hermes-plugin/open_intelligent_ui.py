"""OpenIntelligentUI's ordered artifact contract, adapted to Hermes chat.

Pure assembly: no file/network/model operations or execution of generated code.
The iPhone renders complete artifacts in an opaque, network-denied sandbox.
"""
import json
import re

FIELDS = ('title', 'summary', 'initialHeight', 'placeholderMessages', 'css', 'html', 'jsFunctions', 'jsExpressions')

def selection_prompt(session_info=None):
    if str((session_info or {}).get('platform') or '').lower() in {'photon', 'sms', 'imessage', 'bluebubbles', 'telegram'}:
        return ''
    return ('Use text for facts. For savings, budgets or comparisons with changing inputs, '
            'load skill openintelligentui and render without an explicit UI request. '
            'Prefer native cards; use calculator for numeric scenarios.')

SCHEMA = {
    'name': 'generateSandboxedUi',
    'description': 'Prepare one OpenIntelligentUI interactive answer for Alice. Use text/native cards for simple answers. No external action or model call. Preparing and displaying this artifact does not require Task approval. Only a follow-up question proposed by its controls requires the person to review and send it. Emit the returned fence once in your final answer; prepared does not mean displayed.',
    'parameters': {'type': 'object', 'additionalProperties': False, 'properties': {
        'title': {'type': 'string', 'minLength': 1, 'maxLength': 160},
        'summary': {'type': 'string', 'minLength': 1, 'maxLength': 2000, 'description': 'Accessible plain-text fallback with units, assumptions and provenance.'},
        'initialHeight': {'type': 'integer', 'minimum': 180, 'maximum': 900},
        'placeholderMessages': {'type': 'array', 'minItems': 2, 'maxItems': 4, 'items': {'type': 'string', 'minLength': 1, 'maxLength': 120}},
        'css': {'type': 'string', 'maxLength': 20000},
        'html': {'type': 'string', 'minLength': 1, 'maxLength': 80000},
        'jsFunctions': {'type': 'string', 'maxLength': 60000},
        'jsExpressions': {'type': 'string', 'maxLength': 10000},
    }, 'required': list(FIELDS)}
}
PROMPT = '''## Respuestas interactivas de Alice
Texto para hechos, escritura y respuestas sencillas; tablas Markdown para valores exactos; tarjetas alice-ui para lugares, agenda y borradores. Si explorar variables ayuda, genera una interfaz. Lee la skill openintelligentui para el contrato. Para escenarios numéricos usa alice-ui type calculator; para interfaces libres usa alice-interactive. Escribe directamente un único bloque en la respuesta final: Alice lo valida, sin buscar ni llamar herramientas. Usa generateSandboxedUi solo si necesitas validación previa en Hermes. Controles locales, nunca consultas automáticas al modelo. Cada resultado es una instantánea nueva. Datos reales necesitan evidencia; etiqueta supuestos y muestras. Nunca claves, pagos o acciones externas en una interfaz generada. Usa los colores --color-text-primary y --color-background-primary del host, nunca colores fijos para superficies/texto. No afirmes que se mostró antes de que Alice lo reciba. En SMS/iMessage/Telegram responde solo texto.'''

# Tool guidance + discoverable skill avoid displacing Hermes' existing 8k prompt sections.
SCHEMA["description"] += "\n" + PROMPT


def prepare(args):
    if not isinstance(args, dict) or set(args) != set(FIELDS):
        raise ValueError('Provide exactly the eight documented fields.')
    limits = {'title': 160, 'summary': 2000, 'css': 20000, 'html': 80000, 'jsFunctions': 60000, 'jsExpressions': 10000}
    for key, limit in limits.items():
        value = args[key]
        if not isinstance(value, str) or len(value) > limit or (key in ('title', 'summary', 'html') and not value.strip()):
            raise ValueError('Invalid ' + key)
        if '```' in value or '\x00' in value:
            raise ValueError('Fence delimiters and NUL are not permitted.')
    height = args['initialHeight']
    if type(height) is not int or not 180 <= height <= 900:
        raise ValueError('initialHeight must be an integer from 180 to 900.')
    messages = args['placeholderMessages']
    if not isinstance(messages, list) or not 2 <= len(messages) <= 4 or any(not isinstance(x, str) or not x.strip() or len(x) > 120 for x in messages):
        raise ValueError('Provide 2–4 short placeholder messages.')
    if re.search(r'<\s*(?:script|style|iframe|object|embed|form|meta|base)\b', args['html'], re.I):
        raise ValueError('HTML contains a forbidden element; put styles and scripts in their channels.')
    if re.search(r'type\s*=\s*[\'\"]?password\b', args['html'], re.I):
        raise ValueError('Credential fields are forbidden.')
    # Preserve the documented streaming order after the two accessibility fields.
    artifact = {key: args[key] for key in FIELDS}
    return {'status': 'prepared', 'fallback': args['summary'],
            'reply_block': '```alice-interactive\n' + json.dumps(artifact, ensure_ascii=False, separators=(',', ':')) + '\n```'}


def plain_fallback(text):
    def replace(match):
        try:
            return prepare(json.loads(match.group(1)))['fallback']
        except (ValueError, TypeError):
            return 'La interfaz interactiva no está disponible en este canal.'
    text = re.sub(r'```alice-interactive\s*\n(.*?)\n```', replace, text, flags=re.S)
    def native(match):
        try:
            payload = json.loads(match.group(1))
            if payload.get('type') != 'calculator':
                return match.group(0)
            summary = payload.get('summary')
            if isinstance(summary, str) and summary.strip() and len(summary) <= 2000:
                return summary
        except (ValueError, TypeError, AttributeError):
            pass
        return 'La interfaz interactiva no está disponible en este canal.'
    return re.sub(r'```alice-ui\s*\n(.*?)\n```', native, text, flags=re.S)
