# Envelope-native model

Status: active ownership contract after Budget-domain retirement

## Purpose

The Household needs separate meanings for:

- accounting facts: what actually happened,
- Plans: what is expected, completed, or still committed,
- Envelopes: what household capacity has been granted to a purpose,
- Backing: which real Asset funding supports those outstanding claims.

`Budget` is not a separate domain object in this model. A future requirement may
introduce a new Budget concept, but it must be designed from that requirement
rather than restored from compatibility types.

Physical names such as `budget.journal`, `budget.toml`, `budget:*` Accounts, and
BudgetMovement writer vocabulary are migration/source contracts. They do not own
the Envelope semantics described here.

## Final ownership map

```text
EnvelopeRegistry
    |
    +------------------------------ stable Envelope identity only

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

Asset balances + BackingPolicy + Envelope claims
    |
    v
BackingPoolPosition

CurrentEnvelopePolicy
    |
    +------------------------------ current label/pacing/presentation only
```

There is no second Budget state beside this graph.

## One fact, one owner

A fact is written or admitted once and projected elsewhere.

- Actual Expense use belongs to `ActualJournal`.
- Plan intent belongs to `PlanJournal`.
- Plan completion belongs to Plan/Actual relation evidence.
- Envelope grant/reallocation belongs to `EnvelopeEntitlementHistory`.
- Expense-to-Envelope meaning belongs to `ExpenseRoutingHistory`.
- non-Expense target intent belongs to `FulfillmentRoutingHistory` by stable
  `PlanId`.
- current funding topology belongs to `BackingPolicy`.
- stable Envelope existence belongs to `EnvelopeRegistry`.

Consumption, fulfillment, remaining, commitment, headroom, and backing are
observations. They must not be written back as duplicate facts.

## Accounting boundary

The accounting chart contains accounting categories only:

```text
Asset
Liability
Equity
Income
Expense
```

An Envelope is not an Account. Entitlement, commitment, remaining capacity,
target fulfillment, and backing are not accounting balances.

A savings, investment, liability-payment, or other non-Expense target remains an
ordinary accounting transaction. Its Envelope meaning comes from explicit Plan
intent, never from the destination Account alone.

## Envelope identity

Each spendable Envelope has a stable `EnvelopeId`. `EnvelopeRegistry` owns the
admitted identity universe and nothing else.

The Registry contains no:

- label,
- pacing,
- Expense route,
- BackingPool assignment,
- entitlement amount,
- current active/retired state.

Those coordinates have different lifetimes. Removing an Envelope from current
configuration must not erase historical identity.

The final physical identity source is deliberately not fixed here. If an
append-only declaration/lifecycle history becomes necessary, it receives its own
owner. Current TOML must never become retrospective identity authority.

## Current Envelope policy

`CurrentEnvelopePolicy` is deliberately thin. Its final responsibility is current
operational/presentation information such as:

- `EnvelopeId`,
- human label,
- current pacing/display mode,
- current membership/visibility if required by the UI.

It does **not** own:

- Expense Account routing,
- BackingPool definitions or Envelope-to-pool assignments,
- entitlement history,
- historical identity.

Those already have independent owners.

The current implementation still carries Expense Account assignments and a
`BackingPolicy` inside `CurrentEnvelopePolicy`. That is migration coupling, not
the target ownership boundary. A shared TOML file may still be parsed into
several admitted domain owners; sharing physical syntax does not require one
aggregate owner.

### Pacing

Pacing is current policy, not historical fact. The implementation currently
needs `Daily` and `Flex` behavior. Additional presentation/operational modes such
as a protected Reserve mode may be added when a concrete requirement needs them;
they must not alter old Actual, routing, or entitlement evidence.

Do not split pacing into more axes until a real combination requires it.

## Entitlement history

Envelope history owns explicit grant/reallocation decisions only:

```text
Unallocated -> Envelope
Envelope    -> Envelope
Envelope    -> Unallocated
```

Conceptually:

```haskell
data EnvelopeEndpoint
  = Unallocated
  | Spendable EnvelopeId
```

`Unallocated` is not an Envelope and not an Asset balance. It is the entitlement
space not currently granted to a spendable Envelope. Whether real assets can
support that entitlement is a separate Backing question.

Every transfer preserves exact amount, commodity, date, period, identity,
provenance, and writer authority. Conflicting or unknown coordinates fail closed.

The current `budget.journal` projection through retained Budget Accounts is a
source adapter into this owner. Opening/execution/unassigned Budget Account roles
are not native Envelope concepts and must not leak past that adapter.

## Expense routing and consumption

Expense consumption is derived from admitted Actual Expense postings plus an
effective-dated Expense routing history.

```text
Expense Account @ effective day -> ManagedByEnvelope EnvelopeId
Expense Account @ effective day -> NotEnvelopeManaged
```

Missing routing is attention evidence. Conflicting routing fails closed.
Historical targets are validated against stable identity, never by replaying
latest TOML.

Refunds and typed Actual reversals affect consumption through Actual evidence.
No compensating Envelope movement is written.

Current configuration may help an editor create a new routing declaration, but
it must not become a second routing authority.

## Fulfillment routing and fulfillment

Savings, investment, debt reduction, and similar non-Expense goals are distinct
from Expense consumption.

Their Envelope intent is attached to stable Plan identity:

```text
PlanId @ effective day -> FulfillsEnvelope EnvelopeId
PlanId @ effective day -> NotFulfillmentTarget
```

A completed routed Plan produces `EnvelopeFulfillment` from Plan/Actual evidence.
Actual quantities remain authoritative. Shared Accounts do not transfer Envelope
meaning between unrelated Plans.

Typed reversal chains cancel or restore the root fulfillment evidence without
re-inferring intent from reversal Accounts.

## Commitment

Commitment is the still-open Plan claim against Envelope capacity.

There is no separate `CommitmentRoutingHistory`.

- open Expense Plan postings use `ExpenseRoutingHistory`,
- open non-Expense target Plans use `FulfillmentRoutingHistory`,
- unrelated Plans create no Envelope claim.

This is intentional: the same declared intent that will later explain
Consumption or Fulfillment explains the open commitment before completion.
Creating another routing owner would duplicate meaning.

For an open Plan, routing is observed at the current observation day because the
Plan is still current intent. Completed historical fulfillment uses the route at
the completing Actual evidence boundary.

## Remaining and headroom

These are exact arithmetic projections with explicit `Period` and observation
`Day` alignment:

```text
Remaining
  = Entitlement
  - Consumption
  - Fulfillment

Headroom
  = Remaining
  - Commitment
```

Negative Remaining is valid overspending/over-fulfillment evidence. Negative
Headroom is valid over-commitment evidence. Neither value is silently clamped.

Current labels, pacing, presentation order, and attention policy stay outside
these arithmetic owners.

## Household Envelope observation

The final Household composition should produce one native observation from
already admitted owners:

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
  routing attention
```

It should not contain `HouseholdPolicy` as semantic state. Current policy joins
later when a report or UI needs labels, pacing, order, or presentation.

The current `Household.EnvelopeObservation` still accepts
`HouseholdBudgetMovement`, `HouseholdAccountPolicy`, and retained Budget Account
classification in order to adapt the existing canonical source into
`EnvelopeEntitlementHistory`. That is migration infrastructure, not the final
observation boundary.

## Backing

Backing is separate from Envelope capacity.

```text
Asset Accounts -> BackingPool
EnvelopeId     -> BackingPool
```

`BackingPolicy` owns the current funding topology. It is not part of
`CurrentEnvelopePolicy` and it does not claim historical truth.

Backing compares real admitted Asset funding with outstanding Envelope claims.
Pool coordinates remain visible before Household aggregation so shortage in one
pool cannot be erased by surplus in another.

`EnvelopeRemaining` and `EnvelopeHeadroom` remain distinct inputs/metrics:
Remaining expresses the outstanding granted claim after completed use; Headroom
expresses how much of that claim is not already committed by open Plans.

If historical Backing reports later require policy-as-of-time, introduce an
effective-dated Backing policy history then. Do not make every current policy
historical preemptively.

The production `Household.Backing` path still contains migration compatibility:
legacy destination-Account Plan reserve, retained Budget Account reconciliation,
and direct entitlement-minus-consumption calculation. The target is to consume
native `EnvelopeRemaining` / `EnvelopeHeadroom` plus independent `BackingPolicy`
instead.

## Historical safety

Current configuration is not retrospective truth.

Changing today's label, pacing, routing preference, or backing topology must not
silently rewrite already admitted historical intent.

Historical owners are introduced only where history affects meaning:

- stable Envelope identity,
- entitlement transfers,
- Expense routing,
- PlanId fulfillment routing.

Backing policy remains current until a historical Backing requirement exists.
Presentation policy remains current unless a concrete historical presentation
requirement exists.

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

A source adapter may translate legacy syntax, but it may not create new semantic
facts.

## Migration boundary

The following are deliberately source-compatibility debt, not native Envelope
concepts:

- physical `budget.journal` and `budget.toml` names,
- retained `Budget` AccountType / `budget:*` Accounts,
- `HouseholdBudgetMovement*` writer vocabulary,
- opening/spent/unassigned Budget Account roles,
- `PlanBudgetSync`,
- legacy `plan-destination-accounts` intent authority.

Do not rename these first and repair semantics later. Replace their admission and
writer responsibilities with the native owners, qualify the replacement, then
retire the old source contract.

In particular, `plan-destination-accounts` must be replaced by stable `PlanId`
fulfillment intent, not moved under a new name.

## Implementation direction after Budget removal

The next architectural work is therefore bounded:

1. finish qualification of the Budget-domain removal branch without restoring
   legacy owners,
2. thin `CurrentEnvelopePolicy` so Expense routing and Backing are independent,
3. complete `HouseholdEnvelopeObservation` with Fulfillment, Remaining,
   Commitment, and Headroom,
4. make Household Backing consume native Remaining/Headroom and independent
   `BackingPolicy`,
5. remove retained Budget-Account and destination-Account adapters only after
   replacement source admission and writer paths are qualified,
6. consider physical source renames only after semantics and writer authority no
   longer depend on the legacy contract.

This is the target architecture. New Envelope work should fit this ownership map
rather than create another aggregate beside it.
