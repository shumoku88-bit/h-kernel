# Envelope-native model

Status: design contract before Budget removal

## Purpose

The household needs three independent meanings around spending:

- accounting facts: what actually happened,
- Plans: what is expected or committed,
- Envelopes: what household funds are permitted or intended for.

`Budget` is not a separate domain object in this model. If a future requirement
needs a broader Budget concept, it must be introduced from that requirement
rather than retained as an empty compatibility layer.

## Accounting boundary

The accounting chart contains only accounting categories:

```text
Asset
Liability
Equity
Income
Expense
```

An Envelope is not an Account. Allocation, reservation, remaining capacity, and
backing are not accounting balances.

Actual Expense postings remain owned by the Actual Journal. Envelope consumption
is derived from those admitted postings and is not written again to an Envelope
history.

## Envelope identity and current policy

Each spendable Envelope has a stable identity. Current operational policy may
assign:

- a human label,
- an Envelope mode,
- Expense routing,
- a BackingPool.

These policy values do not rewrite historical allocation facts.

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
mirror Actual consumption or Plan completion.

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

The exact source shape is intentionally not fixed by this document yet. Source
migration must preserve identity, exact amount, commodity, date, cycle,
provenance, writer authority, and fail-closed admission.

`Unallocated` is not a spendable Envelope identity. It is the backing capacity
not currently granted to spendable Envelopes.

## Derived Envelope observation

At one Household observation:

```text
entitlement      = admitted allocation history
consumption      = routed Actual Expense postings
remaining        = entitlement - consumption
plan reservation = routed still-open Plan commitments
available        = remaining - plan reservation
```

Refunds and Actual reversals change consumption through Actual facts. They do
not require compensating Envelope-history writes.

Plan completion produces or relates to Actual. It does not write a second
Budget/Envelope consumption transaction.

## Routing and historical safety

TOML is current policy, not automatically historical truth. Changing a current
Expense-to-Envelope default must not silently reinterpret old observations.

The Budget-removal implementation must therefore preserve or introduce durable
routing evidence wherever current configuration alone would cause historical
reclassification. The exact owner may be an admitted relation or another named
historical coordinate, but it must not be inferred retrospectively from the
latest TOML.

Unrouted declared Expense Accounts remain valid attention evidence. Conflicting
routes fail closed.

## Backing

Backing answers which admitted Asset funding supports current Envelope claims.

```text
Asset accounts -> BackingPool -> Envelope claims
```

BackingPool coordinates remain visible before Household aggregation. A shortage
in one pool must not be erased by surplus in another pool.

Open Plans may create both Asset-pool commitments and Envelope reservations.
Plan source and destination therefore remain separate evidence.

There is no `unassigned Budget Account`. Unallocated backing is derived from
funding and granted Envelope claims.

## Migration boundary

The current canonical `budget.journal` / `budget.toml` source contract remains
unchanged until the replacement admission and writer path are qualified. Do not
rename files first and repair semantics afterwards.

The implementation should remove, rather than rename, concepts that exist only
to support Budget Accounts, including Plan Budget sync and Budget-account
execution/spent/unassigned roles. Laws that remain meaningful are migrated to
their Envelope, Plan, Actual, or Backing owners.
