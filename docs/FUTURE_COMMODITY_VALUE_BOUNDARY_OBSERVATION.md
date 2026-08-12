# Future Commodity / Value Boundary Observation

Status: observation only
Date: 2026-08-11
Scope: future-proofing review; no implementation roadmap

## Purpose

Record which value-domain distinctions h-kernel should preserve if a future Household needs more than today's ordinary fiat-money workflows.

This document does not request multi-currency reporting, securities, crypto assets, points, FX, valuation, lots, settlement, import, or reconciliation now.

The rule is:

> Missing future capability is acceptable. A current type/source decision that makes the future meaning impossible to add without silently changing historical meaning is the risk.

Do not use this observation to justify speculative type hierarchies, generic finance frameworks, or unused fields.

## Current kernel evidence

`HKernel.Money` already has a strong general shape:

```text
Commodity
Quantity
Amount = Commodity × Quantity
Balance = Commodity -> Quantity
```

`Commodity` is deliberately not restricted to ISO 4217 and its documentation names JPY, USD, and BTC as examples. `Quantity` is an exact finite base-10 value rather than binary floating point. `Amount` has no `Num` instance. Cross-commodity composition goes through `Balance`, where equal commodities combine and different commodities remain separate.

This is an important future-proofing property. Preserve it.

The current Account model may carry an optional default Commodity. That default is account metadata and an interaction/input convenience; it is not a universal source-value authority and not a valuation rule.

The Household primary Commodity is likewise an ordinary interaction/default coordinate, not a restriction that the accounting kernel has only one possible Commodity.

## Currency pressure cases worth keeping in view

Supporting every currency now is unnecessary. A few intentionally different examples expose hidden assumptions better than a large code list.

```text
JPY  -> ordinary zero-fraction household money
USD  -> ordinary two-fraction money and ambiguous "$" symbol family
EUR  -> major external household currency and currency-transition destination
ILS  -> concrete non-JPY two-fraction household currency
GBP  -> another major two-fraction currency
CHF  -> accounting precision and physical cash denomination need not be identical policy
INR  -> digit grouping/presentation is locale policy, not Quantity semantics
KWD  -> three-fraction money; "currency always has 0 or 2 decimals" is false
```

These are characterization ideas, not a closed `Currency` ADT proposal. In particular, do not narrow `Commodity` to a finite list just to model common fiat currencies.

## Commodity is wider than currency

A future Household could plausibly need quantities such as:

```text
shares / investment funds
crypto assets
precious metals
reward points / miles
stored-value balances
foreign cash
physical inventory
another user-defined unit
```

No such feature is required now.

The existing `Commodity` type already leaves this door open. Keep currency-specific presentation or registry policy outside the core Commodity identity rather than changing `Commodity` itself into a currency enum.

If a future requirement needs richer identity than one text code, introduce that richer identity from concrete evidence. Do not pre-emptively turn `Commodity` into a large security master model.

## Non-equivalences to preserve

Future work should keep these meanings separable:

```text
commodity identity != display symbol
commodity identity != display name
quantity != value
quantity != reporting value
source amount != current market value
cost != price observation
cost != valuation
price observation != valuation policy
transaction date != settlement date
transaction date != price observation date
lot identity != commodity identity
account identity != commodity identity
account default Commodity != source amount authority
Household primary Commodity != accounting-domain restriction
current configuration != historical evidence
external/import identity != ledger transaction identity
recorded != cleared != reconciled
```

A capability may not need every coordinate. It must not collapse two distinct meanings merely because current fixtures happen to make them equal.

## Quantity and value

The most important future distinction is:

```text
quantity != value
```

Examples:

```text
10 FUND-X
0.005 BTC
25,000 POINTS
```

are quantities. They do not inherently have a JPY, USD, or EUR value.

If valuation is needed later, the direction should remain conceptually:

```text
original Quantity
+ separate price evidence
+ explicit valuation coordinate/policy
-> reporting value
```

Do not replace the original Amount with a converted amount. Do not add a base-currency value to every current Amount merely to reserve the future.

## Cost, price, valuation, and lot

Investment-like commodities introduce meanings that ordinary cash does not force us to model today:

```text
Cost
  acquisition consideration/history for a quantity

PriceObservation
  an observed exchange relationship at a stated time/source

Valuation
  a report-time interpretation using selected price evidence/policy

Lot
  distinguishable acquired quantity carrying acquisition history
```

The future-proofing laws are only:

```text
Cost != PriceObservation != Valuation
Lot != Commodity
```

No production types for these concepts are requested by this observation.

If they become concrete, prefer small named domain types near the capability that owns them. Do not weaken `Amount` into a universal bag of optional finance fields.

## Temporal coordinates

Today's Journal transaction date has a clear existing meaning. Future bank/import/investment workflows may expose other dates:

```text
economic/transaction date
bank posting date
settlement date
price observation date
valuation date
```

Do not add them now. Preserve the current date meaning and add later coordinates by name if a real capability needs them.

This is preferable to retrospectively changing what `transactionDate` meant for old data.

## Reconciliation and external provenance

A future importer/reconciliation workflow may need evidence such as:

```text
external source identity
import source/batch provenance
matching decision
cleared state
reconciled state
statement/reconciliation coordinate
```

These do not belong in monetary arithmetic.

If import becomes real, stable external identity should be usable for replay/duplicate detection where available. Do not make date + description + amount the permanent identity model just because it is convenient for a first importer.

Similarly, reconciliation state should not be encoded by changing the transaction amount, description, Account identity, or durable Actual identity.

## Historical stability

Long-lived Household records outlive current defaults and classifications.

Possible future changes include:

- currency retirement or transition;
- security ticker/name changes;
- point-programme rule changes;
- Account closure/reclassification;
- display/precision policy changes;
- valuation-policy changes.

Preserve:

```text
current configuration/policy
!= historical transaction identity/evidence
```

A new current default must not silently rewrite an old Amount's Commodity or an old event's meaning. Historical correction should remain explicit and attributable.

## Haskell-specific guardrails

For h-kernel specifically:

- keep `Commodity` open and validated rather than replacing it with a fiat-only enumeration;
- keep `Quantity` exact and avoid binary floating-point monetary semantics;
- keep `Amount` single-Commodity and avoid a universal `Num Amount` instance;
- keep `Balance` as separated per-Commodity quantities rather than inventing implicit conversion;
- keep Account default Commodity and Household primary Commodity as defaults/metadata, not valuation or source-authority shortcuts;
- do not add Cost/Price/Lot/Settlement/Reconciliation fields to `Amount`, `Posting`, or `Transaction` until a concrete owner needs them;
- when richer future meaning appears, prefer a named validated type and explicit projection over optional-field accretion;
- preserve existing identity/provenance and Journal history when introducing any future value layer.

## Useful future characterization witnesses

If work later touches these boundaries, small synthetic laws can expose hidden assumptions:

```text
USD-only Household
EUR-only Household
ILS-only Household
exact KWD-style 3-fraction Quantity
same "$" display symbol with distinct Commodity identities
one non-currency Commodity Amount
one Balance containing two Commodities without implicit conversion
same Commodity acquired in two distinct Lots
one acquisition Cost plus a later independent PriceObservation
transaction date distinct from settlement date
same external import replayed with stable external identity
```

None is required to be implemented by this observation PR.

## Relationship to bqn-ledger

bqn-ledger and h-kernel may face the same real-world pressure, but they should not share one implementation architecture by decree.

The shared semantic expectations are only the non-equivalences above: exact quantities, explicit identity, no implicit cross-commodity arithmetic, and separation of original evidence from later valuation/policy.

BQN may naturally express later capabilities as aligned arrays/axes and admission boundaries. Haskell may naturally express them as named validated types and projections. Keep the correspondence semantic rather than copying structure across languages.

## Explicit non-goals

This observation does not authorize:

- a Currency ADT or ISO currency package;
- a generic Commodity registry;
- securities or investment features;
- crypto features;
- points/miles tracking;
- FX APIs or automatic conversion;
- reporting/base currency;
- price database;
- cost-basis or tax-lot engine;
- settlement workflow;
- bank import;
- reconciliation workflow;
- source format migration;
- Journal metadata expansion;
- writer changes;
- private canonical Household changes.

## Decision

The current Money kernel already leaves unusually good room for future value domains. The correct action now is mostly preservation: keep the distinctions visible and resist shortcuts that turn current defaults into universal truths.

Future implementation should begin only from a concrete Household requirement, then add the smallest named meaning that requirement actually needs.
