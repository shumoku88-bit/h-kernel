# Envelope-native model

Status: active ownership contract

## Purpose

The Household separates four meanings:

- accounting facts: what happened,
- Plans: what is expected, completed, or still committed,
- Envelopes: capacity granted to a purpose,
- Backing: real Asset funding supporting outstanding Envelope claims.

`Budget` is not a second domain object beside Envelope. `budget.journal`, `budget.toml`, `budget:*` Accounts, and BudgetMovement writer vocabulary are physical source vocabulary around the native Envelope model.

## Ownership graph

```text
EnvelopeRegistry
  + EnvelopeEntitlementHistory
  -> EnvelopeEntitlement

ActualJournal + ExpenseRoutingHistory
  -> EnvelopeConsumption

PlanJournal + Actual completion evidence + FulfillmentRoutingHistory
  -> EnvelopeFulfillment

EnvelopeEntitlement
  - EnvelopeConsumption
  - EnvelopeFulfillment
  -> EnvelopeRemaining

open PlanJournal
  + ExpenseRoutingHistory
  + FulfillmentRoutingHistory
  -> EnvelopeCommitment

EnvelopeRemaining - EnvelopeCommitment
  -> EnvelopeHeadroom

Asset balances + open Plan funding + BackingPolicy
  + EnvelopeRemaining + EnvelopeHeadroom
  -> BackingPoolPosition
```

There is no intermediate Budget calculation state.

## One fact, one owner

- Actual Expense use belongs to `ActualJournal`.
- Plan intent belongs to `PlanJournal` plus explicit routing evidence.
- Plan completion belongs to Plan/Actual relation evidence.
- Envelope grants and reallocations belong to `EnvelopeEntitlementHistory`.
- Expense-to-Envelope meaning belongs to `ExpenseRoutingHistory`.
- non-Expense Envelope intent belongs to `FulfillmentRoutingHistory` keyed by stable `PlanId`.
- current funding topology belongs to `BackingPolicy`.
- stable Envelope existence belongs to `EnvelopeRegistry`.

Consumption, Fulfillment, Remaining, Commitment, Headroom, and Backing are observations and are never written back as duplicate facts.

## Accounting boundary

An Envelope is not an Account. Entitlement, Commitment, Remaining, Fulfillment, Headroom, and Backing are not accounting balances.

Savings, investment, liability payment, and other non-Expense targets remain ordinary accounting Transactions. Their Envelope meaning comes from explicit Plan intent, never destination Account identity.

## Current policy

`budget.toml` has exactly two semantic owners:

- `CurrentEnvelopePolicy`: current Envelope definition and presentation such as identity membership, label, pacing, order, and visibility;
- `BackingPolicy`: current Asset-pool and Envelope-pool topology.

It does not own Expense routing.

`household.toml` owns explicit Budget source coordinates:

- opening Budget Accounts,
- unassigned Budget Accounts,
- stable allocation Account -> Envelope identity coordinates.

These coordinates classify admitted `budget.journal` endpoints. There is no `spent` or `execution` endpoint in the native entitlement model.

## Entitlement and clean epoch

Envelope Entitlement comes from explicit movements:

```text
Opening/Unassigned -> Envelope
Envelope           -> Envelope
Envelope           -> Unassigned
```

An empty canonical `budget.journal` is valid. Before the first explicit source movement there is no Entitlement stock origin and no claim is inferred from Actual history or current Asset balances.

Entitlement history is admitted globally rather than reset by report Period. Same-day effects combine before cumulative nonnegative validation. The stock origin comes from the earliest admitted Entitlement-source movement for the Commodity, including opening or unassigned evidence that creates no Envelope transfer.

## Expense routing and Consumption

```text
Expense Account @ effective day -> ManagedByEnvelope EnvelopeId
Expense Account @ effective day -> NotEnvelopeManaged
```

Missing routing is attention evidence. Conflicting routing fails closed. Historical routing is never reconstructed from `budget.toml`, Account names, or today's configuration.

Refunds and typed reversals affect Consumption through Actual evidence. No compensating Envelope movement is written.

## Fulfillment

```text
PlanId @ effective day -> FulfillsEnvelope EnvelopeId
PlanId @ effective day -> NotFulfillmentTarget
```

Completed Fulfillment is observed from stable Plan identity plus Actual completion evidence. Actual quantities are authoritative. Reversal chains cancel or restore that evidence without re-inferring intent from Accounts.

Plan completion does not write a Budget execution companion.

## Commitment

Commitment is the still-open Plan claim against Envelope capacity:

- open Expense Plans use `ExpenseRoutingHistory`;
- open non-Expense targets use `FulfillmentRoutingHistory`;
- unrelated Plans create no Envelope claim.

Open routing is observed at the current observation day because it remains current intent. Completed Fulfillment freezes routing at its completion evidence boundary.

## Remaining and Headroom

```text
stock horizon = Entitlement-source origin .. observedThrough

Remaining
  = cumulative Entitlement
  - cumulative Consumption
  - cumulative Fulfillment

Headroom
  = Remaining
  - current Commitment
```

Negative Remaining and Headroom are valid evidence and are not clamped. A report Period boundary does not resurrect previously consumed or fulfilled capacity.

## Household observation

`HouseholdEnvelopeObservation` composes one period/day coordinate with:

```text
entitlement
consumption
fulfillment
remaining
commitment
headroom
```

The outer Period is a statement coordinate, not the lower boundary of live stock terms.

## Backing

Backing is orthogonal to Envelope capacity:

```text
Asset Account -> BackingPool
EnvelopeId    -> BackingPool
```

`BackingPolicy` owns current funding topology. Funding Commitment and Envelope Commitment remain distinct observations.

```text
funding commitment != Envelope commitment
Envelope commitment != destination Account membership
```

Pool coordinates remain visible so shortage in one pool cannot be erased by surplus in another.

## Historical safety

Current configuration is not retrospective truth. Changing today's label, pacing, routing, or backing topology must not silently rewrite historical meaning.

Historical owners exist where history changes semantics:

- stable Envelope identity,
- Entitlement stock origins and transfers,
- Expense routing,
- PlanId Fulfillment routing.

## Admission laws

- exact arithmetic
- stable identity
- explicit provenance
- deterministic conflict reporting
- unknown references fail closed
- no current-config fallback for missing historical evidence
- no Account-name inference
- no implicit allocation or amount splitting

Retired `account-policy.*`, `plan-destination-accounts`, Expense-assignment compatibility, `spent`, and `execution` semantics are not adapters in the current model. Completed migration history belongs to Git, not to a compatibility type or current architecture document.
