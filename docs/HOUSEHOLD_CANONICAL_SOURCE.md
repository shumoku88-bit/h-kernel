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
entitlement.journal
envelope.toml
household.toml
report.toml
issues.tsv
```

`HKernel.Application.Config.householdSourcePaths` が一つの `HouseholdRoot` からbasename解決を所有する。CLI、TUI、Report、editorは別のcanonical basenameやfallback sourceを定義しない。

`issue-relations.tsv` は、この八つの `HouseholdState` admission sourceとは別に、同じroot配下でexplicit Issue provenanceを記録するroot-relative sidecar coordinateとして登録する。Issue relation workflowだけがこのpathを解決し、missing sourceは「relation historyがまだ存在しない」という明示的な初期状態として扱う。これはlegacy fallback、九番目の暗黙canonical source、または別Household rootではない。

Issue relation sourceを `HouseholdState` / `HouseholdWriteSnapshot` の通常八source observationへ昇格するまでは、Reportや他domain readerがこのsidecarを暗黙に読むことはしない。Relation publicationは既存canonical Actual / Issue sourceとこの明示的provenance sourceを協調して扱い、cross-source reference admissionを別途通す。

追加の `data/` / `config/` directoryやengine別canonical copyをroot内に作らない。欠落sourceをlegacy TSV、sample、current configurationから補わない。

## 3. Current admission inventory

| Source | h-kernel admission owner | typed output / role |
|---|---|---|
| `accounts.journal` | `HKernel.Account.Journal.parseAccountJournal` | `AccountRegistry` |
| `actual.journal` | `HKernel.Loader` + `HKernel.Actual.Journal` | `ActualJournal` |
| `plan.journal` | `HKernel.Loader` + `HKernel.Plan.Journal` | `PlanJournal` |
| `entitlement.journal` | `HKernel.Envelope.Entitlement.Journal` | `EnvelopeEntitlementHistory` (dedicated parser/admission) |
| `envelope.toml` | `HKernel.Envelope.Config.parseCurrentEnvelopeConfiguration` | `CurrentEnvelopePolicy` + `BackingPolicy` |
| `household.toml` | `HKernel.Household.Config` + `HKernel.Household.EnvelopeHistory` | Household policy + explicit historical routing |
| `report.toml` | `HKernel.Report.Config.parseReportConfiguration` | `ReportConfiguration` |
| `issues.tsv` | `HKernel.Household.Issue.TSV.parseHouseholdIssues` | `[HouseholdIssue]` |

`actual.journal`と`plan.journal`のroot textは`HKernel.Loader`で一度観察し、named domain admissionがその結果を使う。`entitlement.journal`はaccounting Journal parserや`AccountRegistry`を経由せず、専用の型付けパーサー・admissionが`EnvelopeRegistry`に対して直接検証する。

Included Account declarations may contribute to a resolved Journal. Included Transactions must not masquerade as root-local Actual or Plan evidence.

`issue-relations.tsv` のsource-local syntaxは `HKernel.Household.Issue.Relation.TSV`、cross-source Issue / Plan / source-durable Actual reference admissionは `HKernel.HouseholdIssue` が所有する。Daily-use `IssueRealizedAs` candidate / publication orchestrationは `HKernel.Editor.IssueRealize` が所有する。

## 4. Source meaning

### Facts and declarations

- `accounts.journal`: Account identity、AccountType (Asset, Liability, Equity, Income, Expense)、optional default Commodity
- `actual.journal`: Actual Transaction、Posting、durable identity、completion / correction relation
- `plan.journal`: Plan identity、schedule、recurrence、lifecycle relation
- `entitlement.journal`: Envelope stock origin (`YYYY-MM-DD origin Commodity`) and transfer (`YYYY-MM-DD alloc Endpoint -> Endpoint Amount Commodity [memo]`) facts and provenance

### Current policy and historical routing

`envelope.toml` admits current active Envelope definition / presentation and current Backing topology only. Expense Account classificationやhistorical routingを所有しない。

`household.toml` owns Cycle、money presentation、Daily Target selection、`[envelope-history]` (stable `EnvelopeRegistry` identities, historical Expense routing, Fulfillment routing). Budget tableやAccount-to-Envelope coordinate mappingは所有しない。

Daily Target selection comes from `household.toml`; reservation evidence comes from admitted `plan.journal`. Retired TSV is not re-read or inferred.

Missing Expense routing never falls back to current Envelope configuration. Entitlement transfer endpoint meaning is strictly `Unallocated` or `Spendable EnvelopeId`. `Unallocated` is a boundary endpoint, not a balance-owning account.

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
- `entitlement.journal`
- `issues.tsv`

This is one coordinated Household observation boundary, not a generic repository/session abstraction.

`issue-relations.tsv` is not currently a `HouseholdState` field or ordinary `HouseholdWriteSnapshot` byte coordinate. `IssueRealize` reads its explicit root-relative coordinate together with the admitted Household observation, validates the complete relation candidate against admitted Issue / Plan / durable Actual identities, and gives its own three-source publication intent an exact existence+bytes fence. That bounded sidecar handling must not be generalized into hidden reader fallback.

## 6. Envelope lifetime law

Current Envelope membership and stable historical identity have different lifetimes. Every current Envelope needs a stable identity in `EnvelopeRegistry` (`household.toml [envelope-history]`). Historical identity may remain after an Envelope leaves current presentation policy while retained source evidence still refers to it.

A retired Envelope identity in `EnvelopeRegistry` is historical evidence, not current writer authority. Current writers must not create new transfers involving an Envelope absent from current `envelope.toml` (`CurrentEnvelopePolicy`).

A clean Envelope epoch may begin with an empty `entitlement.journal`. Entitlement or stock origin does not exist until explicit source origin / transfer evidence exists. Initial money is not inferred from Actual history or current configuration.

## 7. Retired source law

Legacy sources such as `budget.journal`, `budget.toml`, `accounts.tsv`, `plan.tsv`, `budget_alloc.tsv`, `cycle.tsv`, `config.tsv`, `daily_target_scope.tsv`, and legacy report manifests are not current bootstrap inputs and have no fallback path.

Retired TOML syntax, including `[budget]`, `account-policy.*`, `plan-destination-accounts`, and current Expense assignment compatibility fields, is rejected rather than preserved as opaque compatibility state.

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
