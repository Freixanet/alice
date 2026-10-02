# QA ledger

One line per finding fixed: date · finding · cause · fix · test.

- 2026-10-02 · I2: a second press of «Pagar» went through · a press was written once in the ledger and no gate looked at it again · a press marks its entry; another is refused until purchase_outcome · sim `pay_twice`, test_qa
- 2026-10-02 · HOOK: two result notes could drop each other · Hermes keeps only the first string of transform_tool_result · one hook chains the plugin's rewrites · test_every_result_note_reaches_the_agent_even_when_two_apply
- 2026-10-02 · COVERAGE: five purchase tools missing from the map · map written by hand · coverage checks every tool and status · qa.py coverage
- 2026-10-02 · I5: login card said «no se ha pagado nada» during a bank code after approval · text not tied to payment state · uses paymentUnconfirmed · qa static nothing-paid
- 2026-10-02 · STATIC: egress guard let code through when its check failed · except returned None · asks the person · qa static fail-open
- 2026-10-02 · I5: «Ya pagada» stop shown as payment unconfirmed · paymentUnconfirmed ignored the stop kind · excludes paid_before · sim `bought_here_earlier_today`, ErrandTests
- 2026-10-02 · SIM: setup crash with two faults combined · seeding used the broken ledger · reorder; simulator failures are findings · fuzz
- 2026-10-02 · iOS journey: on the Errands screen «Comprarla a …», «Seguir desde aquí» and «Cancelar» of a stopped purchase did nothing · ErrandDetailScreen left ErrandStack's actions at `{}` · passes them like the chat · PurchaseJourneyTests, qa static inert-action, test_qa
- 2026-10-02 · STATIC inert-action: the reminder tick in the agenda search did nothing · AgendaItemRow without onTick · picks the reminder · qa static inert-action
- 2026-10-02 · iOS: a Prozis basket (/checkout/index) read as «Checkout» · stage rules checked «checkout» before the basket · basket first · ErrandTests
- 2026-10-02 · SIM: the QA dashboard failed the app's cards and notes routes · no Hermes profiles there · one default profile · ios-server.log
