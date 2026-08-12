# Future Commodity and Value Boundary Observation

## Purpose

This document establishes permanent architectural guardrails for Money, Commodity, Quantity, Amount, and Balance in `h-kernel`. It ensures that present defaults do not become universal restrictions, while preventing premature abstractions (such as currency enums, automatic FX conversion, or tax-lot engines) from inflating the Money kernel.

## Current Evidence

The core Money kernel (`HKernel.Money`) enforces five fundamental accounting invariants:

- `Commodity`: validated text identity representing a unit of account.
- `Quantity`: exact decimal arithmetic (`Scientific`), free from binary floating-point representation errors.
- `Amount = Commodity × Quantity`: single-Commodity monetary magnitude.
- `Balance = Commodity -> Quantity`: multi-Commodity balance map where different commodities are retained separately and never implicitly offset.
- `Account default Commodity` and `Household primary Commodity`: interaction and reporting defaults, not domain restrictions on posting validity.

Fraction digits, display symbols, and locale formatting belong to presentation policy and must not alter `Quantity` arithmetic or `Commodity` identity.

## Non-Equivalences to Preserve

Future work must preserve these semantic distinctions:

```text
commodity identity != display symbol / name
quantity != value
quantity != reporting value
cost != price observation
cost != valuation
price observation != valuation policy
lot identity != commodity identity
account default Commodity != amount authority
Household primary Commodity != accounting-domain restriction
current policy != historical evidence
```

`Amount` represents an exact recorded magnitude in its native `Commodity`. If valuation or reporting currency conversion is required in the future, it must exist as explicit external price evidence and valuation policy, never by mutating the original `Amount` or replacing it with a converted value.

## Guardrails

- **Keep Commodity open**: Maintain `Commodity` as a validated text identity. Do not replace it with a closed fiat-currency enumeration or ISO currency package.
- **Keep Quantity exact**: Retain exact decimal representation. Do not introduce binary floating-point monetary arithmetic.
- **Keep Balance separated**: Retain per-Commodity quantities in `Balance`. Do not invent implicit cross-commodity conversion or cancellation.
- **Keep primitives small**: Do not add `Cost`, `Price`, `Lot`, `Settlement`, or `Reconciliation` fields to `Amount`, `Posting`, or `Transaction` until a concrete capability with a named owner requires them.
- **Preserve historical evidence**: Current configuration or display policy changes must not retroactively rewrite historical transaction identity, commodity, or event evidence.

## Explicit Non-Goals

This observation explicitly forbids:

- a closed Currency ADT or fiat currency package;
- a generic Commodity registry or security master model;
- automatic FX conversion, price databases, or exchange-rate APIs;
- securities, crypto, or reward-point tracking engines;
- tax-lot or cost-basis management engines;
- settlement, bank import, or reconciliation workflows;
- optional finance or workflow fields inside `Amount`, `Posting`, or `Transaction`.

## Decision

The current Money kernel provides a clean, exact foundation for multi-commodity accounting. The primary responsibility now is preservation: keep `Commodity` open, `Quantity` exact, and `Balance` un-mixed, while resisting shortcuts that turn convenience defaults into domain restrictions or prematurely expand core primitives.
