# Household History and Policy Observation

> **Status**: DRAFT / OBSERVATION
> **Role**: temporal semantics for Household interaction and canonical-source relationships
> **Parent Draft**: PR #160

## Purpose

h-kernel may be used for years while Account classification, Budget policy, Envelope assignment, Issue taxonomy, report presentation, and other TOML-owned policy evolve.

A dangerous implementation would recompute every old household decision from today's configuration and silently make the past look as if the current policy had always been in force.

This note records the opposite direction:

> **Current policy guides current/future interpretation and decisions. Historical evidence records what was actually decided or realized at the time.**

The two may agree, but they are not the same semantic owner.

## Concrete failure shape

Suppose the Household used this policy in 2026:

```toml
[expense-assignment]
expenses:furniture = "flex"
```

A chair Issue is eventually realized as an Actual purchase and the Household deliberately treats that purchase as consumption from `flex`.

Years later the current policy changes:

```toml
[expense-assignment]
expenses:furniture = "reserve"
```

If historical reports simply re-run the 2026 Actual through the current TOML, the old purchase now appears to have consumed `reserve`.

That is not merely a new report view. If `flex` was the Household's actual decision at the time, the recomputation has rewritten the meaning of history.

## Three distinct questions

Long-lived Household data needs to distinguish at least these views.

```text
1. Historical evidence
   What actually happened / what did the Household decide at the time?

2. Current policy
   How should a new candidate be classified or handled now?

3. Current analytical projection
   How would old facts look under today's taxonomy or reporting scheme?
```

A current analytical projection may be useful. It must not masquerade as historical evidence.

## Core temporal law

For every semantic coordinate introduced into h-kernel, ask:

> **May this value legitimately change for an old event when current policy changes?**

If yes, it is a projection or current interpretation.

If no, it belongs to durable historical evidence owned by the domain that made or realized the decision.

The distinction can be summarized as:

```text
derived-from-current-policy
          !=
historically-committed-evidence
```

Do not preserve history by copying every configuration file into every event. Preserve only the semantic evidence that must remain true about the old event.

## Canonical Household owners

The current canonical target already separates owners:

```text
accounts.journal
  Account identity / type / Account-specific default Commodity

actual.journal
  what economically happened, postings, durable Actual identity,
  completion / correction / reversal provenance

plan.journal
  commitments, schedule, recurrence, Plan lifecycle

budget.journal
  ordered Budget decisions / movements and their provenance

budget.toml
  current general Budget policy

household.toml
  current Household-specific policy

report.toml
  current report / presentation policy

issues.tsv
  user-authored Household matters that are not accounting facts by themselves
```

This separation should remain meaningful across time. Mutable policy files should not become retroactive owners of facts that were already historically decided elsewhere.

## Issue lineage is historical context, not duplicate accounting

A Household Issue may lead to no accounting event, one Actual, several Actuals, or a Plan that later leads to Actual.

```text
Issue
  |-- dropped ---------------------------------> no accounting fact
  |
  |-- resolved --------------------------------> may have no accounting fact
  |
  |-- promoted-to --> Plan -- completed-by ---> Actual
  |
  `-- realized-by -----------------------------> Actual
                         \----------------------> Actual ...
```

Important consequences:

- `Resolved` does not mean `realized as Actual`.
- `Dropped` is not an Actual cancellation fact.
- one Issue must not be prematurely constrained to exactly one Actual;
- Issue lineage should identify related domain values rather than duplicate their amounts, postings, Accounts, or Budget results;
- an Issue should remain understandable after realization instead of disappearing into the resulting transaction.

The Issue answers part of **why this matter existed**. Actual answers **what happened economically**.

## Following an Issue into accounting and Budget meaning

A realized Issue should be able to lead a reader through the owners that explain its outcome.

Conceptually:

```text
Why was this considered?
Issue
  |
  v
What was committed?
Plan                     (when applicable)
  |
  v
What actually happened?
Actual
  |
  v
Which Accounts / postings expressed it?
Ledger / Account
  |
  v
How did Household capacity get consumed or moved?
Budget / Envelope evidence
```

This does **not** mean `issues.tsv` should grow copies of `expense = furniture`, `envelope = flex`, or the final Actual amount merely so an Issue screen can display them.

If those values have a proper canonical owner, the Issue view should follow identity/provenance and project the owned values.

## Budget classification is where temporal semantics become critical

Some Budget results are pure derivations. Others may represent a real Household decision.

Example A, safely derivable:

```text
immutable Actual posting
  -> immutable Account semantics
  -> a timeless mapping whose meaning is explicitly intended to be recomputed
```

If the entire relationship is genuinely timeless, no extra historical evidence is needed.

Example B, historically meaningful decision:

```text
Issue: buy chair
  -> Actual: 4,800 JPY
  -> Household chooses to consume Flex rather than Reserve
```

If `Flex` was a meaningful choice made at realization time, that choice must not later change merely because `budget.toml` maps furniture differently.

The eventual design therefore needs to determine which Budget coordinates are:

```text
current-policy derivations
historical decisions
historical movements
current analytical classifications
```

and give each exactly one owner.

Do not solve this by storing a full `budget.toml` snapshot on every transaction. Prefer the smallest durable semantic coordinate that proves the historical decision.

## Account category and taxonomy changes

The same distinction applies to categories.

Suppose a 2026 Issue was recorded under a `Want` vocabulary, while a future taxonomy prefers `PurchaseDecision`.

There are two legitimate operations:

```text
Historical view
  -> preserve the original kind/meaning that was recorded

Current analytical view
  -> project the old Issue into the current taxonomy
```

A source migration can also deliberately rewrite canonical vocabulary, but that is an explicit migration with known semantics. It is not the same as silently reading an old fact through a new TOML table.

The same rule applies to Account grouping, report categories, Envelope names, status groupings, and future Household classification coordinates.

## Historical correction is different from retroactive policy

History is not immutable in the sense that mistakes can never be corrected.

A correction should be an explicit Household operation with appropriate identity/provenance semantics.

```text
old historical evidence
  -> explicit correction / migration
  -> corrected historical evidence
```

That is materially different from:

```text
old historical evidence
  + newly edited TOML
  -> silently different past
```

The first is accountable change. The second is accidental reinterpretation.

## UI / report implication

A future Issue detail or history view should be able to distinguish historical and current interpretation when both are useful.

For example:

```text
Chair purchase

Recorded issue:       Want
Realized by:          actual-chair-2026
Actual amount:        4,800 JPY
Historical budget:    Flex

Current analysis:
  current category:   PurchaseDecision
  current budget map: Reserve
```

This is only an explanatory sketch. Exact labels and whether both views should be visible by default remain undecided.

The important rule is that the UI must not display a current-policy projection as though it were the original decision.

## Application-boundary implication

Delivery adapters should not decide temporal semantics.

```text
TUI / CLI / GUI / AI
        |
        v
named Household observation / operation
        |
        +--> historical evidence owner
        |
        `--> current policy / analytical projection
```

An AI secretary may explain that today's policy would classify an old purchase differently, but it must not mutate or reinterpret the historical record merely to make it match current policy.

## Candidate executable laws

When implementation reaches these relationships, useful characterization tests include:

1. changing current Budget policy does not change a historically committed Budget decision;
2. changing current Issue/report taxonomy does not silently rewrite the original Issue meaning;
3. current analytical projection may change after policy change, while historical projection remains stable;
4. Issue -> Plan -> Actual lineage retains stable identities across later policy edits;
5. one Issue may relate to multiple Actuals without collapsing their independent identities;
6. resolving an Issue without an Actual remains representable;
7. historical correction requires an explicit operation rather than implicit config reinterpretation.

These are candidate laws, not claims that the current implementation already satisfies them.

## Still undecided

- exact source representation for `Issue -> Plan` and `Issue -> Actual` provenance;
- whether Issue lineage belongs in `issues.tsv`, target metadata, or another existing owner after concrete writer analysis;
- which Budget/Envelope classifications are timeless derivations versus historically committed decisions;
- the minimal durable coordinate needed to preserve historical Envelope consumption;
- whether some policy decisions need effective dates, event-owned evidence, or explicit Budget movement records;
- how current analytical reclassification should be exposed in reports;
- migration semantics when an old taxonomy itself is intentionally retired;
- whether the historical view should be the default everywhere or only in history/detail surfaces.

Do not choose a generic event-sourcing framework or configuration-versioning system before these concrete owner questions are answered.

## Working rule

> **Settings guide decisions. History testifies to decisions.**

Current policy may change freely. Old Household meaning changes only through an explicit correction/migration or because the value was deliberately defined as a current projection in the first place.

This distinction should become a review question whenever a new canonical coordinate, TOML mapping, Issue relationship, Budget classification, or report projection is introduced.
