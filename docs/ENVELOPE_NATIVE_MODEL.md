# Envelope-native model

Status: design contract during Budget removal

## Purpose

The household needs three independent meanings around spending and saving:

- accounting facts: what actually happened,
- Plans: what is expected or committed,
- Envelopes: what household funds are permitted or intended for.

`Budget` is not a separate domain object in this model. If a future requirement
needs a broader Budget concept, it must be introduced from that requirement
rather than retained as an empty compatibility layer.

The native Envelope semantics are now partly implemented. Canonical Household
source migration remains deliberately separate until replacement admission and
writer paths are qualified.

## Accounting boundary

The accounting chart contains only accounting categories:

```text
Asset
Liability
Equity
Income
Expense
```

An Envelope is not an Account. Allocation, reservation, remaining capacity,
target fulfillment, and backing are not accounting balances.

Actual Expense postings remain owned by the Actual Journal. Envelope consumption
is derived from those admitted postings and is not written again to an Envelope
history.

A savings, investment, or other non-Expense target likewise remains an accounting
transaction in its ordinary Accounts. Its Envelope meaning is explicit Plan
intent, not a property inferred from the target Account.

## Envelope identity and current policy

Each spendable Envelope has a stable `EnvelopeId`. The admitted historical
identity universe is owned by `EnvelopeRegistry`, independently from current
configuration.

The Registry contains existence only. It does not carry label, mode,
BackingPool, Expense routing, allocation amount, or active/retired state. Those
coordinates have different lifetimes. In particular, removing an Envelope from
current policy must not make its historical identity cease to exist, and an
Envelope may exist before receiving any entitlement.

The physical source that will populate the canonical Registry remains unfixed.
It may eventually be derived from an append-only declaration history, but current
TOML must not be treated as retrospective identity authority.

Current operational policy may assign:

- a human label,
- an Envelope mode,
- a BackingPool.

Expense routing and Plan target-fulfillment routing are historically observable
relations described separately below. Current display/calculation policy must
not be mistaken for retrospective truth.

### Envelope mode

```haskell
data EnvelopeMode
  = Daily
  | Flex
  | Reserve
```

The modes are current calculation and presentation policy:

- `Daily`: participates in remaining-days pacing and the Daily display group.
- `Flex`: keeps cycle-level capacity without per-day pacing and appears in the
  Flex display group.
- `Reserve`: keeps cycle-level capacity outside ordinary pacing and appears in a
  protected Reserve display group.

The mode is not part of accounting metadata and is not a historical allocation
coordinate. Changing an Envelope from Daily to Flex does not reinterpret old
Actual facts or old allocation movements.

Do not split mode into independent axes until a real requirement needs a
combination that the three modes cannot express.

## Envelope history

Envelope history owns explicit household allocation decisions only. It does not
mirror Actual consumption, Plan completion, or target fulfillment.

A transfer is one atomic decision with one provenance-bearing record:

```text
Unallocated -> Envelope
Envelope    -> Envelope
Envelope    -> Unallocated
```

The target domain shape is conceptually:

```haskell
data EnvelopeEndpoint
  = Unallocated
  | Spendable EnvelopeId

data EnvelopeMovement = EnvelopeMovement
  { movementDate      :: Day
  , movementCycle     :: Period
  , movementFrom      :: EnvelopeEndpoint
  , movementTo        :: EnvelopeEndpoint
  , movementAmount    :: PositiveAmount
  , movementNote      :: Text
  }
```

The exact canonical source shape is intentionally not fixed by this document
yet. Source migration must preserve identity, exact amount, commodity, date,
cycle, provenance, writer authority, and fail-closed admission.

`Unallocated` is not a spendable Envelope identity. It is the backing capacity
not currently granted to spendable Envelopes.

## Expense consumption

Expense consumption is derived from admitted Actual Expense postings and an
effective-dated Expense routing history.

The routing coordinate is the Expense Account because that Account is the
accounting meaning being classified for Envelope consumption. A declared Expense
Account may be explicitly unmanaged. Missing routing remains attention evidence,
and conflicting routing decisions fail closed.

Refunds and typed Actual reversals change consumption through Actual evidence.
They do not require compensating Envelope-history writes.

A source-local TSV admission exists for the effective-dated Expense routing
history with the coordinate shape:

```text
effective_from / expense_account / route / target / note
```

That admission establishes physical syntax only. The canonical Household path,
writer authority, and snapshot participation are still deliberately unfixed.
Cross-source admission proves that the routed Account exists in the admitted
AccountRegistry, that its declared type is `Expense`, and that a
`ManagedByEnvelope` target belongs to the stable EnvelopeRegistry. An explicit
`NotEnvelopeManaged` decision requires an admitted Expense Account but performs
no Envelope target check. Historical targets are never validated by replaying
current TOML, because that would silently rewrite old intent.

## Non-Expense target fulfillment

Savings, investment, and similar goals are not Expense consumption. A completed
Plan may nevertheless fulfill an Envelope target when that intent is declared
for the stable `PlanId`.

The routing coordinate is therefore `PlanId`, not Account:

```text
PlanId -> FulfillsEnvelope EnvelopeId
PlanId -> NotFulfillmentTarget
```

This distinction is required because one bank, savings, investment, or liability
Account may participate in unrelated Plans and Actual transactions. Sharing an
Account must not transfer Envelope meaning between those facts.

Plan completion remains an explicit relation between Plan and Actual facts.
Generic completion may relate one Actual to several Plans. An Envelope
projection that would need to divide one Actual between several routed target
Plans fails closed rather than inventing an allocation rule.

When a routed Plan completes, Plan/Actual posting shape may be validated
positionally. Account order, direction, and commodity coordinates must agree;
Actual quantities remain authoritative and may differ from planned quantities.
Repeated use of one Account therefore does not collapse target evidence into a
whole-Account net.

Target route identity is observed at the root completing Actual date. Typed
reversal chains cancel or restore that root fulfillment evidence without
re-inferring meaning from the reversal transaction's Accounts.

A source-local TSV admission now exists for the effective-dated PlanId routing
history with the coordinate shape:

```text
effective_from / plan_id / route / target / note
```

That admission establishes physical syntax only. The canonical Household path,
writer authority, and snapshot participation are still deliberately unfixed.
Cross-source admission proves both that the PlanId belongs to the admitted Plan
identity universe and that a `FulfillsEnvelope` target belongs to the stable
EnvelopeRegistry. A historical target is never validated by replaying current
TOML, because that would silently rewrite old intent.

## Plan observation and commitment

Plan lifecycle/completion observation is role-neutral. Being an open or completed
Plan does not itself imply Income, Expense, Liability, or another accounting
role.

This permits Asset-to-Asset savings/investment Plans to remain ordinary
accounting Plans rather than pretending to be generic outgoing Expense flows.
The narrower accounting-outgoing projection remains available for callers that
actually require that role.

For Envelope commitment/headroom:

- positive Expense postings use Expense Account routing,
- positive non-Expense postings claim Envelope headroom only when their stable
  `PlanId` has explicit fulfillment intent,
- unrelated Asset/Liability Plans do not manufacture Envelope claims,
- open Plan routing is observed at the current observation day because the Plan
  remains current intent.

## Derived Envelope observation

At one Household observation:

```text
entitlement        = admitted allocation history
expense consumption = routed Actual Expense postings
target fulfillment  = routed completed non-Expense Plans using Actual evidence
remaining           = entitlement - expense consumption - target fulfillment
open commitment     = routed still-open Plan commitments
headroom            = remaining - open commitment
```

Expense refunds/reversals affect Expense consumption. Reversal chains rooted in
a completed target Plan affect target fulfillment. Neither path writes a second
Budget/Envelope transaction.

## Routing and historical safety

Current TOML is policy, not automatically historical truth. Changing current
configuration must not silently reinterpret old observations.

The native model therefore separates two historical routing meanings:

- Expense Account routing answers which Envelope owns Expense consumption at a
  given time,
- PlanId fulfillment routing answers whether one stable Plan represents a
  non-Expense Envelope target at a given time.

Neither relation may be reconstructed retrospectively from the latest Account
classification or TOML defaults.

## Backing

Backing answers which admitted Asset funding supports current Envelope claims.

```text
Asset accounts -> BackingPool -> Envelope claims
```

BackingPool coordinates remain visible before Household aggregation. A shortage
in one pool must not be erased by surplus in another pool.

Open Plans may create both Asset-pool commitments and Envelope commitments. Plan
source and target meaning therefore remain separate evidence. An Account shared
by several Plans cannot by itself identify an Envelope target.

There is no native `unassigned Budget Account`. Unallocated backing is derived
from funding and granted Envelope claims.

## Migration boundary

The current canonical `budget.journal` / `budget.toml` and Household
`plan-destination-accounts` contract remains in production until replacement
admission and writer paths are qualified. Do not rename or delete sources first
and repair semantics afterwards.

`plan-destination-accounts` is legacy Account-based intent authority. The native
replacement must use the PlanId fulfillment relation instead of moving that
Account lookup under a new name.

The implementation should remove, rather than rename, concepts that exist only
to support Budget Accounts, including Plan Budget sync and Budget-account
execution/spent/unassigned roles. Laws that remain meaningful are migrated to
their Envelope, Plan, Actual, or Backing owners.
