# Household source admission inventory

ステータス: current ownership inventory  
更新日: 2026-08-16

## 目的

現在の `h-kernel` が一つの canonical `HouseholdRoot` から読む source と admission owner を記録する。Migration history、retired compatibility source、writer authority はこの inventory へ混ぜない。

## Canonical Household root

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

`HKernel.Application.Config.householdSourcePaths` が basename 解決を一箇所で所有する。CLI、TUI、Report feature は別の canonical basename や fallback source を定義しない。

```text
HouseholdRoot
  -> householdSourcePaths
  -> source-specific admission
  -> HouseholdState
  + exact mutable root bytes
  -> HouseholdWriteSnapshot
```

## Current inventory

| Source | admission owner | typed output / role |
|---|---|---|
| `accounts.journal` | `HKernel.Account.Journal.parseAccountJournal` | `AccountRegistry` |
| `actual.journal` | `HKernel.Loader` + `HKernel.Actual.Journal` | `ActualJournal` |
| `plan.journal` | `HKernel.Loader` + `HKernel.Plan.Journal` | `PlanJournal` |
| `budget.journal` | `HKernel.Loader` + `HKernel.Household.BudgetMovement` | ordered Envelope allocation movement evidence |
| `budget.toml` | `HKernel.Envelope.Config.parseCurrentEnvelopeConfiguration` | `CurrentEnvelopePolicy` + `BackingPolicy` |
| `household.toml` | `HKernel.Household.Config` + `HKernel.Household.EnvelopeHistory` | Household policy + explicit historical routing owners |
| `report.toml` | `HKernel.Report.Config.parseReportConfiguration` | `ReportConfiguration` |
| `issues.tsv` | `HKernel.Household.Issue.TSV.parseHouseholdIssues` | `[HouseholdIssue]` |

`budget.toml` admits exactly two current semantic owners: current Envelope definition / presentation and current Backing topology. It does not admit Expense assignment compatibility.

`household.toml` owns explicit opening / unassigned Budget Account coordinates and stable allocation Account -> Envelope identity coordinates. Historical Expense and Fulfillment routing are admitted separately from the same physical source.

Budget movement endpoint classification does not use `account-policy.*`, Account names, or `budget:spent`. Plan intent does not use destination Account inference. Retired source coordinates are rejected rather than preserved as opaque compatibility state.

## Journal root observation

Actual、Plan、Budget root text is parsed once through `HKernel.Loader`; named domain admission consumes that observation rather than independently reconstructing the same source.

Included Account declarations may contribute to the resolved Journal. Included Transactions must not masquerade as root-local transaction evidence.

## HouseholdWriteSnapshot

`HouseholdWriteSnapshot` retains exact root bytes only where coordinated publication requires stale-source protection:

- `accounts.journal`
- `actual.journal`
- `plan.journal`
- `budget.journal`
- `issues.tsv`

This is not a generic repository/session abstraction.

## Retired source law

Legacy sources such as `accounts.tsv`, `plan.tsv`, `budget_alloc.tsv`, `cycle.tsv`, `config.tsv`, `daily_target_scope.tsv`, and legacy report manifests are not current bootstrap inputs and have no fallback path.

Retired syntax inside canonical TOML, including `account-policy.*`, `plan-destination-accounts`, and current Expense assignment fields, is not admitted compatibility input.

## Daily Target

Daily Target selection comes from `household.toml`; Plan reservation evidence comes from admitted `plan.journal`. No retired TSV is re-read or inferred.

## Household Report

```text
HouseholdState
  -> admitted Actual / Plan / Envelope / Backing / Issue inputs
  -> HKernel.Household.Report
  -> HouseholdReportSurface
  -> HKernel.Household.Report.Render
```

Report composition does not own source basenames, compatibility parsers, or a second Budget calculation model.

## Invariants

- exact Quantity / Commodity
- stable identity and explicit provenance
- one Household observation boundary for coordinated writes
- explicit historical routing, never current-config fallback
- unknown source meaning fails closed
- no generic source parser or repository/session abstraction without a concrete need
- completed migration adapters do not return to the application path
