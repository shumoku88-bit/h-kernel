# Household canonical source contract

ステータス: アクティブな正規architecture contract  
Owner: canonical Household source shape、source role、reader admission、engine-neutral meaning

## 1. この文書の役割

private `household-ledger-data` repository の root を、`h-kernel` と `bqn-ledger` が共有する唯一の canonical Household root として扱う。

この文書は、canonical basename、source role、h-kernel admission owner、reader topology、historical/current意味の境界を所有する。Writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。

完了したmigration手順、legacy compatibility source、過去のreader topologyはGit履歴へ置き、current contractへ残さない。

## 2. Canonical root

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

`HKernel.Application.Config.householdSourcePaths` が一つの `HouseholdRoot` からbasename解決を所有する。CLI、TUI、Report、editorは別のcanonical basenameやfallback sourceを定義しない。

追加の `data/` / `config/` directoryやengine別canonical copyをroot内に作らない。欠落sourceをlegacy TSV、sample、current configurationから補わない。

## 3. Current admission inventory

| Source | h-kernel admission owner | typed output / role |
|---|---|---|
| `accounts.journal` | `HKernel.Account.Journal.parseAccountJournal` | `AccountRegistry` |
| `actual.journal` | `HKernel.Loader` + `HKernel.Actual.Journal` | `ActualJournal` |
| `plan.journal` | `HKernel.Loader` + `HKernel.Plan.Journal` | `PlanJournal` |
| `budget.journal` | `HKernel.Loader` + `HKernel.Household.BudgetMovement` | ordered Envelope allocation movement evidence |
| `budget.toml` | `HKernel.Envelope.Config.parseCurrentEnvelopeConfiguration` | `CurrentEnvelopePolicy` + `BackingPolicy` |
| `household.toml` | `HKernel.Household.Config` + `HKernel.Household.EnvelopeHistory` | Household policy + explicit historical routing |
| `report.toml` | `HKernel.Report.Config.parseReportConfiguration` | `ReportConfiguration` |
| `issues.tsv` | `HKernel.Household.Issue.TSV.parseHouseholdIssues` | `[HouseholdIssue]` |

`actual.journal`、`plan.journal`、`budget.journal`のroot textは`HKernel.Loader`で一度観察し、named domain admissionがその結果を使う。同じroot sourceをfeatureごとに再parseして別authorityを作らない。

Included Account declarations may contribute to a resolved Journal. Included Transactions must not masquerade as root-local Actual、Plan、Budget evidence.

## 4. Source meaning

### Facts and declarations

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transaction、Posting、durable identity、completion / correction relation
- `plan.journal`: Plan identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered Envelope allocation movement evidence and provenance

### Current policy and historical routing

`budget.toml` admits current active Envelope definition / presentation and current Backing topology only. Expense Account classificationやhistorical routingを所有しない。

`household.toml` owns Cycle、explicit opening / unassigned Budget Account coordinates、stable allocation Account -> Envelope identity coordinates、Daily Target selection、explicit Expense / Fulfillment routing history.

Daily Target selection comes from `household.toml`; reservation evidence comes from admitted `plan.journal`. Retired TSV is not re-read or inferred.

Missing Expense routing never falls back to current Envelope configuration. Budget movement endpoint meaning is derived only from explicit opening / unassigned / allocation coordinates. `spent` endpoint、Account名、`account-policy.*` はauthorityではない。

Plan-to-Envelope intent belongs to effective-dated Fulfillment routing keyed by stable `PlanId`. Destination Account names are not authority.

`report.toml` owns typed Report query defaults and presentation policy. `issues.tsv` is a user-authored Household notebook and does not implicitly generate accounting or Envelope facts.

## 5. Household observation and write snapshot

```text
HouseholdRoot
  -> householdSourcePaths
  -> source-specific admission
  -> HouseholdState
  + exact mutable root bytes
  -> HouseholdWriteSnapshot
```

`HouseholdWriteSnapshot` retains exact root bytes only where coordinated publication needs stale-source protection:

- `accounts.journal`
- `actual.journal`
- `plan.journal`
- `budget.journal`
- `issues.tsv`

This is one coordinated Household observation boundary, not a generic repository/session abstraction.

## 6. Envelope lifetime law

Current Envelope membership and stable historical identity have different lifetimes. Every current Envelope needs a stable allocation coordinate and identity. Historical identity may remain after an Envelope leaves current presentation policy while retained source evidence still refers to it.

A retired allocation coordinate is historical evidence, not current writer authority. Current writers must not create new movements through an Envelope absent from current `budget.toml`.

A clean Envelope epoch may begin with an empty `budget.journal`. Entitlement or stock origin does not exist until explicit source movement evidence exists. Initial money is not inferred from Actual history or current configuration.

## 7. Retired source law

Legacy sources such as `accounts.tsv`, `plan.tsv`, `budget_alloc.tsv`, `cycle.tsv`, `config.tsv`, `daily_target_scope.tsv`, and legacy report manifests are not current bootstrap inputs and have no fallback path.

Retired TOML syntax, including `account-policy.*`, `plan-destination-accounts`, and current Expense assignment compatibility fields, is rejected rather than preserved as opaque compatibility state.

## 8. Engine-neutral semantic contract

```text
canonical Household source
  -> source-specific semantic admission
     -> h-kernel typed values
     -> bqn-ledger array-native values
```

The engines share source meaning, not internal representation.

- preserve exact Quantity / Commodity
- preserve Account、Plan、Actual、movement identity and provenance
- preserve source order where order is semantic
- fail closed on unknown or ambiguous coordinates
- do not infer historical meaning from current configuration
- do not create duplicate canonical copies or dual authority
- do not weaken identity or provenance for reader compatibility

Source-specific parsers remain source-specific. One Household root does not imply one generic parser, generic event model, or generic repository/session abstraction.

## 9. Writer and evolution boundary

Read capability、write capability、canonical source ownership、operational writer authority are distinct. Source-specific writer authority and publication gates are owned by [`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md).

A writer must not reconstruct facts from compatibility syntax、presentation config、another source's derived observation、or a retired coordinate.

When the canonical source contract changes:

- establish the semantic owner before changing physical shape
- preserve exactness、identity、provenance、source order
- remove completed migration shells instead of keeping fallback compatibility
- qualify every engine that consumes the shared coordinate before deleting it
- never reinterpret current configuration as historical evidence
- keep completed migration history in Git, not active architecture docs

## 10. Non-goals

- public replication of private Household contents
- UI-owned domain semantics
- compatibility aliases for retired source meaning
- generic source/repository abstractions without a concrete invariant
- treating the current eight-file physical shape as permanently immutable
