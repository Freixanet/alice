# Auditoría: de seis a dieciocho casos fallidos

## Corrección de seguridad posterior

La explicación anterior de `70e7914` era demasiado amplia: varios cambios de
pruebas retiraron garantías, no solo actualizaron fixtures. Las compras quedan
desactivadas. Se restauran el vínculo a la pestaña original, invalidación por
cambios de cookies de sesión, rechazo de formatos aún sin comprobar y cancelación
por respuesta vacía de login con spies de Vault, reanudación y ejecución de pago.
La segunda aprobación vuelve a rechazarse con 409; no se afirma idempotencia de
cargos mediante un mero contador de reanudaciones. La opción publicada se compara
con el quote verificado por identidad. «No lo tengo» para OTP conserva su conducta
de recuperación hasta aclarar ese caso con el usuario.


## Origen demostrado

Los doce casos adicionales se originaron en `283bbaa` (importación del plugin
que estaba instalado en el Mac). Los doce pasan en su padre `1fc290c` y fallan en
`283bbaa`. No aparecieron por primera vez en las nuevas herramientas de Watchers
ni Tasks: entraron en `codex/proactive-watchers` al recuperar la otra rama mediante
`4befbc1`. Los doce pasan en el primer padre de ese merge (`cf2af8a`) y fallan en
el merge y en su segundo padre (`18a214d`).

El informe anterior solo los llamó «previos» respecto a `0e0490e`. Eso no responde
a la comparación con `684c4da`; esta auditoría corrige esa omisión. La fase 2
además amplió el registro de herramientas/secciones, por lo que sus pruebas
ahora incluyen expresamente ese contrato.

Son discrepancias de fixtures/contratos antiguos; no doce fallos nuevos demostrados
en el producto. Se conservan las mejoras recuperadas. Al analizar la protección de
secretos sí se detectó y corrigió el camino inseguro que retiraba la protección
cuando desaparecía el registro del contexto. El arreglo de producción se limita a
ese hook; el resto actualiza las pruebas a los contratos recuperados y añade
comprobaciones de seguridad/idempotencia, sin omitir pruebas ni retirar aserciones
sobre aislamiento, versiones o ejecución única.

## Los doce casos

Todos: origen `283bbaa`; entrada en esta rama durante fase 1: `4befbc1`.

| Caso exacto | Corrección y evidencia |
|---|---|
| `test_business_isolation.BusinessIsolationTests.test_register_adds_the_hooks_and_the_prompt_section` | Prueba del hook compuesto: conserva los cinco transformadores, verifica su orden, evita duplicados y exige la sección Tasks de fase 2. La expectativa anterior exigía hooks separados que Hermes no encadena. |
| `test_errand_hooks.ErrandHookTests.test_resumed_purchase_protects_all_browser_outputs_and_fails_closed` | Fixture con contexto existente para una sesión reanudada. Corrección de producción adicional: si falta el registro, conserva secure_answered, invalida la cesta y bloquea lecturas repetidas; solo browser_exec puede recuperar el contexto aislado. Una prueba nueva verifica ambos caminos. |
| `test_errands.CirclingTests.test_the_engine_stops_a_run_going_round_and_says_why` | La primera vuelta sobre una URL es una advertencia; la segunda sin cambios en el DOM detiene el recado. Fixture de dos vueltas con firma constante; se comprueba que ambos runs se detienen. |
| `test_errands.ContextTests.test_the_preamble_makes_and_then_keeps_one_context_and_tab` | Fixture CDP con Target.getTargetInfo y browserContextId. Nueva prueba rechaza una pestaña ajena; los archivos del fixture quedan en un home temporal. |
| `test_errands_api.ErrandRoutesTests.test_allow_approves_the_checkout_seen_and_resumes_the_errand` | Una repetición idéntica devuelve 200 de forma idempotente. Se exige mismo checkout aprobado y una sola continuación; los IDs distintos/caducados siguen siendo rechazados. |
| `test_notes_tools.NotesToolsTests.test_the_manifest_declares_the_tools_it_provides` | Incluye herramientas recuperadas y las nuevas de fases 1/2. Sigue comparando el conjunto exacto; una prueba adicional exige un handler registrado para cada declaración. |
| `test_purchase_evidence.AccessTests.test_a_login_already_given_is_not_asked_again` | Actualiza el mensaje de error comprobado, conservando rechazo de una segunda petición, estado working y canal OTP separado. |
| `test_purchase_evidence.AccessTests.test_cancel_preserves_offer_without_any_payment_or_vault_write` | Cancelar usa errands.stop (API /stop); una respuesta de login vacía significa intentar invitado. Se comprueban cancelación sin secretos ni continuación, rechazo de invitado no disponible y continuación solo tras verificar esa opción. |
| `test_purchase_evidence.AccessTests.test_changed_origin_or_context_cannot_receive_access` | Rechaza un contexto ajeno y otro origen. Nueva prueba independiente permite una pestaña reemplazada dentro del mismo contexto propio, tal como requiere la recuperación del navegador. |
| `test_purchase_evidence.AccessTests.test_visible_empty_login_recovers_a_prose_only_agent_turn` | Fixture distingue formulario vacío de ruta invitado: antes devolvía true también para la consulta de invitado y simulaba dos estados incompatibles. |
| `test_purchase_evidence.CartRevalidationTests.test_same_price_after_session_change_needs_no_acceptance` | Una cookie renovada no invalida por sí sola la cesta. Se comprueba además que cambiar el contexto propio sí la invalida; precios y cantidades siguen comprobándose. |
| `test_purchase_evidence.EvidenceTests.test_all_found_formats_must_be_accounted_for` | Todos los formatos sin verificar deben aparecer por nombre en unchecked y en las instrucciones de presentación, sin convertirse en ofertas verificadas; las exclusiones confirmadas retiran ese aviso. |

## Verificación

- Comandos históricos aislados: `python3 /private/tmp/alice-audit-twelve.py
  cf2af8a 4befbc1 18a214d HEAD`, y después `283bbaa^ 283bbaa be4f06c^ be4f06c`.
  El runner seleccionó únicamente estos doce casos, usando las pruebas propias de
  cada commit, sin cambiar el checkout del usuario. Archivos y resultados:
  `/private/tmp/alice-failure-audit-20261009/`. No hubo llamadas al modelo.
- Los doce corregidos pasan (12/12).
- Suite completa: `PYTHONPYCACHEPREFIX=/private/tmp/alice-audit-cache
  ~/.hermes/hermes-agent/venv/bin/python -m unittest discover -s hermes-plugin/tests`.
  **668 pruebas, 4 fallos, 2 errores, 19 omitidas**; exactamente los seis mismos
  identificadores del baseline `684c4da`. Log:
  `/private/tmp/alice-post-audit-full-tests.log`.
- Módulo de recados después de añadir la prueba de pestaña ajena y aislar sus
  archivos: **84 pruebas pasan**. Log `/private/tmp/alice-audit-errands-tests.log`.
  Esa prueba adicional se verificó por separado de la suite completa anterior.
- No se ha iniciado fase 3. No se cambió código iOS ni se hicieron compras, pagos,
  pruebas visuales o llamadas de conversación reales. Quedan los seis problemas
  originales, sin ocultarlos ni convertirlos en skips.

## Los seis originales que permanecen

- `test_task_finish.AutoGoalTests.test_an_errand_opens_its_goal`
- `test_ask_person.GoalWaitTests.test_an_open_question_parks_the_goal_and_its_answer_releases_it`
- `test_agent_engine.Safety.test_delayed_hermes_session_is_refused_before_any_move`
- `test_memory_review.HermesReviewTests.test_reads_each_message_once_and_writes_through_hermes`
- `test_task_finish.AutoGoalTests.test_the_same_reply_twice_pauses_the_goal`
- `test_task_finish.FinishTaskTests.test_the_tool_uses_the_chat_turn_session`
