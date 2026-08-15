# Envelope-native model

Status: active ownership contract after Budget-domain retirement

## Purpose

The Household separates four kinds of meaning:

- accounting facts: what actually happened,
- Plans: what is expected, completed, or still committed,
- Envelopes: what household capacity has been granted to a purpose,
- Backing: which real Asset funding supports outstanding Envelope claims.

`Budget` is not a second domain object beside Envelope. Physical names such as
`budget.journal`, `budget.toml`, `budget:*` Accounts, and BudgetMovement writer
vocabulary remain source-migration contracts only.

## Native ownership graph

```text
EnvelopeRegistry
    |
    +------------------------------ stable Envelope identity

EnvelopeEntitlementHistory
    |
    v
EnvelopeEntitlement

ActualJournal + ExpenseRoutingHistory
    |
    v
EnvelopeConsumption

PlanJournal + Actual completion evidence + FulfillmentRoutingHistory
    |
    v
EnvelopeFulfillment

EnvelopeEntitlement
  - EnvelopeConsumption
  - EnvelopeFulfillment
    |
    v
EnvelopeRemaining

open PlanJournal
  + ExpenseRoutingHistory
  + FulfillmentRoutingHistory
    |
    v
EnvelopeCommitment

EnvelopeRemaining
  - EnvelopeCommitment
    |
    v
EnvelopeHeadroom

Asset balances + open Plan funding + BackingPolicy
  + EnvelopeRemaining + EnvelopeHeadroom
    |
    v
BackingPoolPosition
```

There is no intermediate Budget calculation state in this graph.

## One fact, one owner

A fact is written or admitted once and projected elsewhere.

- Actual Expense use belongs to `ActualJournal`.
- Plan intent belongs to `PlanJournal`.
- Plan completion belongs to Plan/Actual relation evidence.
- Envelope grant, reallocation, and stock-opening boundary belong to
  `EnvelopeEntitlementHistory`.
- Expense-to-Envelope meaning belongs to `ExpenseRoutingHistory`.
- non-Expense target intent belongs to `FulfillmentRoutingHistory` by stable
  `PlanId`.
- current funding topology belongs to `BackingPolicy`.
- stable Envelope existence belongs to `EnvelopeRegistry`.

Consumption, Fulfillment, Remaining, Commitment, Headroom, and Backing are
observations. They are never written back as duplicate facts.

## Accounting boundary

An Envelope is not an Account. Entitlement, commitment, remaining capacity,
target fulfillment, and backing are not accounting balances.

Savings, investment, liability-payment, and other non-Expense targets remain
ordinary accounting transactions. Their Envelope meaning comes from explicit
Plan intent, never from the destination Account alone.

## Envelope identity

Each spendable Envelope has a stable `EnvelopeId`. `EnvelopeRegistry` owns the
admitted identity universe and nothing else. Labels, pacing, routing, backing
assignment, entitlement, and current visibility have different lifetimes and do
not belong to stable identity.

Removing an Envelope from current configuration must not erase historical
identity.

## Current Envelope policy

`CurrentEnvelopePolicy` owns only current Envelope definition and presentation
coordinates such as label, pacing, order, and visibility.

The retained physical `budget.toml` is one source boundary but is admitted into
three independent current owners:

- `CurrentEnvelopePolicy` for current Envelope definition/presentation,
- `CurrentExpenseAssignments` for retained current operational Expense Account
  assignment compatibility,
- `BackingPolicy` for current funding topology.

`CurrentExpenseAssignments` is not historical routing evidence. Actual and open
Plan Envelope meaning remains owned by `ExpenseRoutingHistory`; missing
historical routing never falls back to the current assignment owner.

A shared physical TOML file may therefore be parsed into several domain owners
without creating one aggregate semantic owner.

## Entitlement

Envelope entitlement is derived from explicit grant and reallocation evidence:

```text
Unallocated -> Envelope
Envelope    -> Envelope
Envelope    -> Unallocated
```

`Unallocated` is entitlement space, not an Envelope and not an Asset balance.
Whether real assets support that entitlement is a separate Backing question.

The current canonical `budget.journal` and retained Budget Account roles are a
source adapter into `EnvelopeEntitlementHistory`. Opening, execution, and
unassigned Budget Account vocabulary must not leak beyond that adapter.

Legacy `Envelope <-> spent` execution movements remain readable source-era
records, but the Entitlement adapter deliberately ignores them. Plan completion
no longer appends new execution movements to `budget.journal`.

Entitlement history is globally admitted rather than reset by report Period.
For each `(EnvelopeId, Commodity)`, same-day transfer deltas combine before an
ascending cumulative scan, and any negative historical balance fails closed even
when a later transfer restores it or the defect is after the requested
observation day.

`EnvelopeEntitlementHistory` also owns the stock opening boundary for each
Commodity. A generic transfer-only constructor may infer that boundary from the
first transfer, but Household production has stronger source evidence: the
adapter derives the origin from the earliest admitted Entitlement-source movement
for that Commodity, including opening or unallocated movement that creates no
native Envelope transfer. This distinction keeps routed Actual use after source
inception visible even when it predates the first grant.

## Expense routing and Consumption

Expense consumption is derived from admitted Actual Expense postings plus
historical routing:

```text
Expense Account @ effective day -> ManagedByEnvelope EnvelopeId
Expense Account @ effective day -> NotEnvelopeManaged
```

Missing routing is attention evidence. Conflicting routing fails closed.
Historical routing is never reconstructed from current configuration.

Refunds and typed Actual reversals affect Consumption through Actual evidence.
No compensating Envelope movement is written.

The bounded `observeEnvelopeConsumption` remains a Period activity observer.
Production Remaining instead uses stock Consumption from the Commodity's
`EnvelopeEntitlementHistory` origin through `observedThrough`. A Period rollover
therefore cannot resurrect capacity already consumed. Reversal chains retain the
root Actual routing date, so a later reversal of pre-origin accounting history
cannot manufacture Envelope capacity after inception.

## Fulfillment routing and Fulfillment

Savings, investment, debt reduction, and similar non-Expense goals are distinct
from Expense Consumption. Their intent is attached to stable Plan identity:

```text
PlanId @ effective day -> FulfillsEnvelope EnvelopeId
PlanId @ effective day -> NotFulfillmentTarget
```

The canonical shared `household.toml` may contain this effective-dated history.
PlanId and EnvelopeId references are cross-source qualified during Household
admission. Absence of routing never falls back to current destination-Account
configuration.

A completed routed Plan produces `EnvelopeFulfillment` from Plan/Actual evidence.
Actual quantities remain authoritative. Reversal chains cancel or restore root
fulfillment evidence without re-inferring intent from Accounts.

The bounded `observeEnvelopeFulfillment` remains a Period activity observer.
Production Remaining uses stock Fulfillment from the same Commodity stock origin
as Consumption. Completion evidence before Envelope-source inception remains
outside stock together with its reversal chain; completed use after inception
remains deducted across later report Periods.

Plan completion does not publish a second Budget execution fact. Fulfillment is
an observation of Plan/Actual evidence, not a `budget.journal` writer action.

## Commitment

Commitment is the still-open Plan claim against Envelope capacity. There is no
separate Commitment routing history.

- open Expense Plan postings use `ExpenseRoutingHistory`,
- open non-Expense target Plans use `FulfillmentRoutingHistory`,
- unrelated Plans create no Envelope claim.

Role-neutral Plans such as Asset-to-Asset savings transfers remain whole in the
full `PlanJournal`. The narrow Planned Transactions report may omit them without
removing them from Envelope observation.

For an open Plan, routing is observed at the current observation day because the
Plan remains current intent. Completed Fulfillment freezes route meaning at the
completing Actual evidence boundary.

Commitment remains a current report/observation-horizon claim. It is not made
cumulative merely because Consumption and Fulfillment are stock terms.

## Remaining and Headroom

These are exact arithmetic projections at an aligned report `Period` and
observation `Day`, but the report Period is not the lower boundary of the stock
terms:

```text
stock horizon = Entitlement-source origin .. observedThrough

Remaining
  = cumulative Entitlement
  - cumulative Consumption
  - cumulative Fulfillment

current report/observation horizon

Headroom
  = Remaining
  - Commitment
```

Negative Remaining is valid overspending or over-fulfillment evidence. Negative
Headroom is valid over-commitment evidence. Neither is clamped.

## Household Envelope observation

Production `HouseholdEnvelopeObservation` owns all six Envelope meanings at one
period/day coordinate:

```text
HouseholdEnvelopeObservation
  period
  observedThrough
  entitlement
  consumption
  fulfillment
  remaining
  commitment
  headroom
```

The outer Period remains the statement/presentation coordinate. It does not
reset live Entitlement, Consumption, Fulfillment, or Remaining. Stock observers
still retain that same Period coordinate so the six meanings compose at one
report point without confusing the report window with the historical stock
horizon.

It does not store `HouseholdPolicy` as semantic state. Current policy is an input
needed while adapting retained canonical source coordinates, not part of the
resulting Envelope observation.

The observation still accepts `HouseholdBudgetMovement` and
`HouseholdAccountPolicy` to project the current canonical allocation source into
native entitlement history. That adapter supplies both native transfers and the
source-owned Commodity stock origins. This is source migration infrastructure.

## Backing

Backing is orthogonal to Envelope capacity.

```text
Asset Account -> BackingPool
EnvelopeId    -> BackingPool
```

`BackingPolicy` owns current funding topology. `Household.Backing` consumes
native `EnvelopeRemaining` and `EnvelopeHeadroom`; it does not recompute
Remaining or infer Envelope Commitment from Plan destination Accounts.

Open Plan funding is observed independently from the role-neutral open Plan set.
Each negative Asset posting before the current funding horizon reserves that
source Asset in its BackingPool. This remains true even when the Plan has no
Envelope route. Conversely, a Plan can claim Envelope Headroom only through
Expense or PlanId routing.

This separation prevents two false implications:

```text
funding commitment != Envelope commitment
Envelope commitment != destination Account membership
```

Pool coordinates remain visible before Household aggregation so shortage in one
pool cannot be erased by surplus in another.

The retained allocation journal is used for source-era unassigned
reconciliation only. It is not a second Envelope claim calculator.

## Historical safety

Current configuration is not retrospective truth. Changing today's label,
pacing, routing preference, or backing topology must not silently rewrite old
intent.

Historical owners exist where history changes meaning:

- stable Envelope identity,
- Entitlement-source stock origins and entitlement transfers,
- Expense routing,
- PlanId fulfillment routing.

Backing policy remains current until a concrete historical Backing requirement
exists. Presentation policy remains current unless a historical presentation
requirement appears.

## Admission laws

Every cross-source admission follows the same laws:

- exact arithmetic,
- stable identity,
- explicit provenance,
- writer authority,
- deterministic conflict reporting,
- unknown references fail closed,
- no fallback from missing historical evidence to current config,
- no implicit allocation or amount splitting.

A source adapter may translate legacy syntax, but it may not invent semantic
facts.

## Retained source vocabulary

The following are deliberately source or compatibility debt, not native Envelope
concepts:

- physical `budget.journal` and `budget.toml` names,
- retained `Budget` AccountType and `budget:*` Accounts,
- `HouseholdBudgetMovement*` writer vocabulary,
- opening, spent, and unassigned Budget Account roles,
- legacy `plan-destination-accounts` syntax.

`plan-destination-accounts` is no longer Envelope claim authority. Stable
`PlanId` fulfillment routing owns that meaning. Do not move destination-Account
intent under a new compatibility type.

The retired `PlanBudgetSync` API and TUI retry flow have been removed. Plan
completion publishes only Plan/Actual relation evidence; native Envelope
observations consume that evidence without a second Budget execution write.

Do not rename physical sources first and repair semantics later. Replace source
admission and writer responsibilities with native owners, qualify the
replacement, then retire the old source contract.

## Next architectural work

After the current-owner and writer cutovers, the remaining bounded work is:

1. continue removing retained Budget-Account adapters only after equivalent
   native source admission and writer paths are qualified,
2. consider physical source renames only after semantics and writer authority no
   longer depend on the legacy contract.

New Envelope work must fit this ownership graph rather than create another
aggregate beside it.