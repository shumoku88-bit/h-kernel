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
- Envelope grant and reallocation belongs to `EnvelopeEntitlementHistory`.
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

`CurrentEnvelopePolicy` is transitional. Its target responsibility is current
operational and presentation information such as label, pacing, order, and
visibility.

It must not become historical authority for:

- Expense routing,
- fulfillment routing,
- entitlement history,
- stable identity,
- historical Backing topology.

The implementation still carries Expense Account assignments and a
`BackingPolicy` inside `CurrentEnvelopePolicy`. That coupling is the next
ownership split. A shared physical TOML file may be parsed into several domain
owners without creating one aggregate semantic owner.

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

## Remaining and Headroom

These are exact arithmetic projections with aligned `Period` and observation
`Day`:

```text
Remaining
  = Entitlement
  - Consumption
  - Fulfillment

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

It does not store `HouseholdPolicy` as semantic state. Current policy is an input
needed while adapting retained canonical source coordinates, not part of the
resulting Envelope observation.

The observation still accepts `HouseholdBudgetMovement` and
`HouseholdAccountPolicy` to project the current canonical allocation source into
native entitlement history. That is source migration infrastructure.

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
- entitlement transfers,
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

The following are deliberately source or writer compatibility debt, not native
Envelope concepts:

- physical `budget.journal` and `budget.toml` names,
- retained `Budget` AccountType and `budget:*` Accounts,
- `HouseholdBudgetMovement*` writer vocabulary,
- opening, spent, and unassigned Budget Account roles,
- `PlanBudgetSync`,
- legacy `plan-destination-accounts` syntax.

`plan-destination-accounts` is no longer Envelope claim authority. Stable
`PlanId` fulfillment routing owns that meaning. Do not move destination-Account
intent under a new compatibility type.

Do not rename physical sources first and repair semantics later. Replace source
admission and writer responsibilities with native owners, qualify the
replacement, then retire the old source contract.

## Next architectural work

After this production cutover, the remaining bounded work is:

1. thin `CurrentEnvelopePolicy` so current presentation/operation, Expense
   routing declarations, and `BackingPolicy` are independent owners,
2. retire `plan-destination-accounts` from active Household policy once its
   source/writer compatibility obligations are explicitly closed,
3. continue removing retained Budget-Account adapters only after equivalent
   native source admission and writer paths are qualified,
4. consider physical source renames only after semantics and writer authority no
   longer depend on the legacy contract.

New Envelope work must fit this ownership graph rather than create another
aggregate beside it.
