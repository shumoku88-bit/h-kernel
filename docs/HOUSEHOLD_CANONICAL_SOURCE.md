# Household canonical source contract

ステータス: current architecture contract  
Owner: canonical Household source shape、source role boundary、engine-neutral semantic contract  
更新日: 2026-08-16

## 目的

private `household-ledger-data` repository の root を、`h-kernel` と `bqn-ledger` が共有する唯一の canonical Household root として扱う。

完了した migration 手順や compatibility source は current contract に残さない。過去の状態は Git 履歴と merged PR が所有する。

## Canonical root

```text
accounts.journal
actual.journal
plan.journal
budget.journal
budget.toml
household.toml
report.toml
issues.tsv
```

追加の `data/` や `config/` directory を canonical root の内側に設けない。application は一つの `HouseholdRoot` からこの8 sourceを解決し、欠落時に legacy source や repository sample へ fallback しない。

## Source roles

### Facts and declarations

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transaction、Posting、durable identity、completion / correction relation
- `plan.journal`: Plan identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered Envelope allocation movement evidence and provenance

### Current domain policy

- `budget.toml`: current active Envelope definition / presentation and current Backing topology only
- `household.toml`: Cycle、explicit opening / unassigned Budget Account coordinates、stable allocation Account -> Envelope identity coordinates、Daily Target selection、explicit Expense / Fulfillment routing history

`budget.toml` does not classify Expense Accounts. Expense-to-Envelope meaning belongs only to explicit `ExpenseRoutingHistory`. Missing routing never falls back to current Envelope configuration.

`household.toml [budget]` owns explicit opening and unassigned coordinates. `household.toml [[budget.envelopes]]` owns allocation Account -> stable Envelope identity coordinates. Budget movement endpoint meaning is derived only from these explicit coordinates; there is no `spent` / `execution` endpoint authority.

Plan-to-Envelope intent belongs to effective-dated Fulfillment routing keyed by stable `PlanId`. Destination Account names are not authority.

`account-policy.*`, `plan-destination-accounts`, and current Expense-assignment compatibility are not canonical coordinates. Unknown retired syntax fails closed rather than becoming opaque state or fallback authority.

### Application policy and notebook

- `report.toml`: typed Report query defaults and presentation policy
- `issues.tsv`: user-authored Household notebook; it does not implicitly generate accounting or Envelope facts

## Envelope lifetime law

Current Envelope membership and stable historical identity have different lifetimes. Every current Envelope needs a stable allocation coordinate and identity. Historical identity may remain after an Envelope leaves current presentation policy when retained source evidence still refers to it.

A retired allocation coordinate is historical evidence, not current writer authority. Current writers must not create new movements through an Envelope absent from current `budget.toml`.

A clean Envelope epoch may begin with an empty `budget.journal`. No entitlement or stock origin exists until an explicit source movement is written. Initial money is not inferred from Actual history.

## Engine-neutral semantic contract

```text
canonical Household source
  -> source-specific semantic admission
     -> h-kernel typed values
     -> bqn-ledger array-native values
```

The engines share source meaning, not internal representation.

- keep exact Quantity / Commodity
- preserve Account、Plan、Actual、movement identity and provenance
- fail closed on unknown or ambiguous coordinates
- do not infer historical meaning from current configuration
- do not create engine-specific canonical copies or dual authority
- do not weaken identity or provenance for reader compatibility

## Household root law

Canonical basename resolution belongs to the application boundary. TUI、CLI、Report and editor surfaces must not independently redefine `actual.journal`, `budget.toml`, or other source identities.

Source-specific parsers remain source-specific. One Household root does not imply one generic parser or generic repository/session abstraction.

## Writer authority

A shared canonical repository, read capability, write capability, and operational writer authority are distinct. Source-specific writer authority and publication gates are owned by [`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md).

A write must not reconstruct facts from compatibility syntax, presentation config, or another source's derived observation.

## Evolution law

When this contract changes:

- establish the semantic owner before changing physical shape
- preserve exactness、identity、provenance and source order
- remove completed migration shells instead of keeping them "just in case"
- qualify both engines before deleting a shared coordinate
- never silently reinterpret current configuration as historical evidence
- keep completed migration history in Git, not in current architecture docs

## Non-goals

- public replication of private Household contents
- UI-owned domain semantics
- compatibility aliases for retired source meaning
- generic event/repository abstractions without a concrete owner
- treating the current eight-file shape as permanently immutable
