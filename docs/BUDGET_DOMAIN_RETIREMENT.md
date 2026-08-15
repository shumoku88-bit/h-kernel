# Budget domain retirement

## Status

The `Budget` domain model is retired from active h-kernel architecture.

This decision removes `Budget` as a second state model beside `Envelope`.
Current household meaning is owned by the narrower native owners:

- stable Envelope identity and current Envelope policy
- historical Expense routing
- Envelope entitlement history and transfers
- Actual consumption and refunds
- Plan commitments and fulfillment
- Backing policy and Backing positions

No active calculation should reconstruct a `BudgetPolicy`, `BudgetObservation`,
`BudgetEntitlement`, `BudgetRemaining`, or an equivalent renamed aggregate.

## Historical documents

The following documents are retained only as design-history evidence:

- `BUDGET_MODEL_OBSERVATION.md`
- `BUDGET_BACKING_OBSERVATION.md`
- `BUDGET_PLAN_COMMITMENT_OBSERVATION.md`

They describe observations that helped produce the Envelope-native model. They
are not current implementation targets, compatibility requirements, or authority
for introducing a new Budget aggregate.

If a future requirement genuinely needs a concept called `Budget`, design it
again from that requirement. Do not infer that the retired model should be
restored merely because these historical observations still exist.

## Names that intentionally remain

This retirement does not rename existing accounting/source vocabulary by
itself. In particular, names such as the accounting `Budget` AccountType,
`budget:*` Account identities, `budget.journal`, `budget.toml`, and
`HouseholdBudgetMovement` may remain while they describe current source or
writer contracts.

Those names do not authorize a separate Budget state model. Any source-name or
accounting-vocabulary migration is a separate change and must preserve canonical
Household data and writer authority.
