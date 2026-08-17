# Budget domain retirement

## Status

The `Budget` domain model and physical accounting vocabulary are retired from active h-kernel architecture.

This decision removes `Budget` as a second state model beside `Envelope`, retires `AccountType` `Budget`, and migrates physical source vocabulary (`budget.journal`, `budget.toml`, `HouseholdBudgetMovement`) into native Entitlement source (`entitlement.journal`, `envelope.toml`, `EnvelopeEntitlementHistory`, `EntitlementTransfer`).

Current household meaning is owned by the native owners:

- stable Envelope identity (`EnvelopeRegistry`) and current Envelope policy (`CurrentEnvelopePolicy`)
- historical Expense routing (`ExpenseRoutingHistory`)
- Envelope entitlement history and transfers (`EnvelopeEntitlementHistory`)
- Actual consumption and refunds (`EnvelopeConsumption`)
- Plan commitments and fulfillment (`EnvelopeCommitment`, `EnvelopeFulfillment`)
- Backing policy and Backing positions (`BackingPolicy`, `BackingPoolPosition`)

No active calculation should reconstruct a `BudgetPolicy`, `BudgetObservation`, `BudgetEntitlement`, `BudgetRemaining`, `AccountType` `Budget`, or an equivalent renamed aggregate.

## Historical evidence

The Budget-model observations that led to this retirement are historical evidence, not current implementation targets, compatibility requirements, or authority for introducing a new Budget aggregate. They are owned by Git history and merged PRs, not by the active documentation set.

If a future requirement genuinely needs a concept called `Budget`, design it again from that requirement. Do not infer that the retired model should be restored from historical implementation or observation records.

## Accounting boundary

Accounting accounts are strictly double-entry: `Asset`, `Liability`, `Equity`, `Income`, `Expense`. Envelopes are not Accounts. Native entitlement transfers operate over `Unallocated` and `Spendable EnvelopeId` endpoints without opening or intermediate double-entry account coordinates.
