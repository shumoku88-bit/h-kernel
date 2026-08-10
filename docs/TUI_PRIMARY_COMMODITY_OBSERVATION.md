# Primary Commodity / Main Currency Observation

> **Status**: OBSERVATION / SOURCE-CONTRACT DESIGN INPUT
> **Scope**: Household configuration + interaction defaults
> **Migration status**: shared source cutover completed; contract tightening and adapter wiring remain
> **Non-goal**: exchange-rate conversion, valuation currency, or restricting the domain to one currency

## Why this exists

Most household bookkeeping is dominated by one currency even when the household occasionally uses one or two others.

The interaction should therefore optimize the ordinary path for one Household-level primary Commodity without reducing the accounting domain to a single Commodity.

```text
Domain
  many Commodities remain valid

Household
  primary Commodity = JPY

Interaction
  primary Commodity is normally omitted
  another Commodity is stated only when needed
```

This follows the broader TUI rule:

> Keep the common path straight; branch only when the situation actually differs.

## Current h-kernel behavior

The current TUI is already partly convenient, but the convenience is not yet fully driven by the Household primary Commodity.

### Ordinary Actual

Quantity-only input such as:

```text
138
```

can already work when the selected Accounts provide one unambiguous default Commodity. This is Account-derived inference.

If selected Account defaults conflict, candidate creation fails closed rather than guessing.

### Other current TUI defaults

Plan Add, Budget Movement, and Account Add currently start with `JPY` as an adapter-level initial value.

That makes the common interaction short, but the presentation code still duplicates a value that now has a canonical Household owner.

## Canonical semantic coordinate

The natural owner is `household.toml`, because this is Household-specific policy shared by delivery adapters and engines.

The canonical source now contains:

```toml
[money]
primary-commodity = "JPY"
```

h-kernel admits this to the existing typed `Commodity` meaning. bqn-ledger admits the same source coordinate in its native representation.

The source name is deliberately `primary-commodity`, not `currency`, because h-kernel accounting already models Commodity and must not silently narrow that model.

The current value `JPY` belongs to this Household. The contract itself does not require JPY; another Household may choose another primary Commodity.

## Meaning

`primary-commodity` means:

- the ordinary Household Commodity used when an interaction genuinely needs a default;
- the Commodity that may be visually omitted in common-entry presentation where the resulting meaning remains unambiguous;
- a candidate default for new Plan / Budget / Account interaction state where no more specific Account-derived default exists.

It does **not** mean:

- all transactions must use this Commodity;
- foreign Commodities require conversion into the primary Commodity;
- reports must value all Commodities in the primary Commodity;
- exchange rates are implied;
- Account default Commodity is replaced;
- the Household may use at most two or three Commodities.

## Default precedence

The useful interaction precedence is:

```text
explicit Commodity supplied by the user
        ↓ otherwise
one unambiguous Commodity implied by the selected Account defaults
        ↓ otherwise
Household primary Commodity
        ↓ otherwise
require an explicit Commodity / fail closed
```

An Account-default conflict is not resolved by silently choosing the Household primary Commodity.

Example:

```text
Account A default = JPY
Account B default = USD
Household primary = JPY
```

This remains ambiguous and should require an explicit decision. The primary Commodity is a convenience default, not authority to erase contradictory evidence.

## Interaction examples

Ordinary JPY expense:

```text
Coffee
138
SMBC -> Food
```

The preview may still show the complete admitted meaning:

```text
Coffee
¥138 JPY
SMBC -> Food
```

A less-common foreign-currency expense can branch explicitly:

```text
Coffee
4.50 USD
Cash USD -> Travel
```

If the selected Accounts already provide an unambiguous USD default, `4.50` alone may be enough without consulting the Household primary Commodity.

## Straight common path, exceptional branch

Primary Commodity is one instance of a broader interaction rule rather than a one-off currency shortcut.

The common case should remain a short, direct path when the Household already knows the ordinary values. Extra controls appear only when reality differs from the default or proposed meaning.

### Plan Complete & Advance

Plan completion needs all of these semantic coordinates because reality may differ from the Plan:

- Actual date
- Actual amount
- next Plan date
- next Plan amount
- whether a successor should exist at all

Those coordinates are not UI clutter to delete. They are meaningful exception coordinates.

The common path can still remain straight:

```text
Internet
Planned: Aug 12 · ¥4,800

Actual
  Aug 12 · ¥4,800

Next
  Sep 12 · ¥4,800

[Enter] Complete & continue
[e] Change
[n] No next Plan
```

If the debit actually occurs on Aug 14 for ¥4,932, only that exception needs to branch into editing. If the next occurrence changes, only the successor branch needs editing.

The rule is therefore:

> Defaults compress the common path; they do not erase the domain coordinates needed when reality differs.

### The same rule elsewhere

```text
ordinary Record
  two postings
    ↓ only when needed
  add another posting

primary Commodity
  omitted
    ↓ only when needed
  explicit USD / EUR / other Commodity

simple Issue
  title and known defaults
    ↓ only when needed
  amount / due date / details
```

This keeps domain strictness intact while avoiding a questionnaire at the start of every routine action.

## Why this belongs below the TUI

CLI, TUI, GUI, and a future AI adapter should not each invent their own `JPY` default.

```text
household.toml
    primary Commodity
          ↓
Household application observation
          ↓
CLI / TUI / GUI / AI candidate preparation
```

This keeps the delivery adapters flexible while the semantic default has one canonical owner.

## Shared-source migration status

`household.toml` is shared by h-kernel and bqn-ledger, and both readers are fail-closed around unsupported source structure. The migration therefore used an expand / cutover / contract sequence rather than changing canonical data first.

Completed:

1. h-kernel gained optional typed `primary-commodity` admission in #166;
2. bqn-ledger gained equivalent strict admission in #627;
3. both reader changes were qualified and merged;
4. canonical `household.toml` was cut over to explicit `[money] primary-commodity = "JPY"`.

Still to do:

5. contract both readers so the canonical coordinate is required rather than migration-optional;
6. replace adapter-level hard-coded `JPY` defaults with the admitted Household coordinate;
7. decide and test the exact quantity-only fallback path from Account defaults to Household primary Commodity.

The expand phase deliberately did **not** introduce a hidden compatibility fallback such as "missing means JPY". Absence remained observable until canonical cutover.

## HCI consequence

This is another instance of progressive disclosure without semantic loss.

The common Household path should not repeatedly ask for a value that is stable and already known. A foreign Commodity remains fully available, but it appears as a branch when the user actually needs it.

The resulting rule is:

> Omit stable Household context from routine input, not from the admitted accounting meaning.
