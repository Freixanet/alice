# Plan de medición · Nombre del proyecto

*Métrica norte:* … · *Herramienta:* … · *Estado:* Borrador · Aprobado · Instrumentado · Verificado (AAAA-MM-DD)

Eventos con nombre `objeto_accion`, en inglés y en pasado (`signed_up`). Sin datos personales en las propiedades.

## Embudo

| # | Paso | Evento | Cuándo se dispara | Propiedades |
| --- | --- | --- | --- | --- |
| 1 | Llega | `landing_viewed` | Primera visita a la landing | origen, campaña |
| 2 | Se registra | `signed_up` | Cuenta creada | método |
| 3 | Onboarding, paso 1 | `onboarding_step_completed` | … | paso = 1 |
| … | Primer valor | `first_value_reached` | Obtiene por primera vez el resultado prometido | minutos desde el registro |
| … | Vuelve | `session_started` | Nueva sesión otro día | días desde el registro |
| … | Paga | `subscription_started` | Primer pago confirmado | plan, precio |

## Definiciones

- **Activación:** …
- **Retención:** … (semana 1 y semana 4)
- **Baja:** …

## Preguntas que los datos deben poder responder

- ¿En qué paso se pierde más gente?
- ¿Cuánto tarda en llegar al primer valor?
- ¿Qué hacen distinto los que se quedan?

## Privacidad

Identificador anónimo, sin datos personales en los eventos y consentimiento cuando la ley lo exija.

## Verificación

- AAAA-MM-DD · evento · cómo se comprobó · @biz-tech
