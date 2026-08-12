# Household source admission inventory

ステータス: 現在状態のownership inventory  
更新日: 2026-08-12

## 目的

この文書は、現在の`h-kernel`が一つのcanonical `HouseholdRoot`から実際に読むsourceと、そのadmission ownerを記録する。

migration history、retained compatibility source、writer authorityはここで現在のreader topologyへ混ぜない。shared canonical contractは[`HOUSEHOLD_CANONICAL_TARGET.md`](HOUSEHOLD_CANONICAL_TARGET.md)、source別writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。

このinventoryは実装へ追従する現在地であり、将来のmodule分割やlayer数を要求するarchitecture templateではない。

## Canonical Household root

現在のapplication bootstrapが解決するsourceは次の8本である。

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

basenameの解決は`HKernel.Application.Config.householdSourcePaths`が一箇所で所有する。CLI、TUI、Report featureが個別にbasenameを組み立て直さない。

```text
HouseholdRoot
  -> householdSourcePaths
  -> source-specific admission
  -> HouseholdState
  + exact mutable root bytes
  -> HouseholdWriteSnapshot
```

`HKernel.Household.Application.loadCanonicalHouseholdWriteSnapshot`がcanonical observation boundaryである。各syntaxを一つのgeneric parserへ畳まず、source-specific ownerがtyped valueへadmitする。

## Current inventory

| Source | 現在のadmission | typed output / role |
|---|---|---|
| `accounts.journal` | `HKernel.Account.Journal.parseAccountJournal` | `AccountRegistry` |
| `actual.journal` | `HKernel.Loader` root observation + `HKernel.Actual.Journal` admission | `ActualJournal` |
| `plan.journal` | `HKernel.Loader` root observation + `HKernel.Plan.Journal` admission | `PlanJournal` |
| `budget.journal` | `HKernel.Loader` root observation + `HKernel.Household.BudgetMovement` admission | `HouseholdBudgetMovementJournal` |
| `budget.toml` | `HKernel.Budget.Config.parseBudgetPolicy` | `BudgetPolicy` |
| `household.toml` | `HKernel.Household.Config.parseHouseholdConfiguration` | `HouseholdConfiguration` / `HouseholdPolicy` |
| `report.toml` | `HKernel.Report.Config.parseReportConfiguration` | `ReportConfiguration` |
| `issues.tsv` | `HKernel.Household.Issue.TSV.parseHouseholdIssues` | `[HouseholdIssue]` |

Account registryはActual、Plan、Budgetのresolved Journal meaningと照合する。source familyごとのadmission failureを黙って欠落値へ変換しない。

## Journal root observation

Actual、Plan、Budgetは、root Textを読んだ直後に同じrootを別経路で再parseしない。

```text
exact root Text
  -> HKernel.Loader root observation
       -> resolved Journal
       -> root transaction-source evidence
  -> named domain admission
```

`HouseholdWriteSnapshot`はcurrent editor operationがpublicationに必要とするexact root bytesを、同じtyped Household observationと結びつけて保持する。現在保持するのはAccounts、Actual、Plan、Budget、Issuesのroot Textである。

このsnapshotはrepository/session abstractionではない。新しいsource bytesを保持するのは、具体的なcoordinated operationが同一observationを必要とするときだけにする。

## Daily Target

`daily_target_scope.tsv`はcurrent canonical Household bootstrapには存在しない。

Daily Targetは、`household.toml`からadmitされたeligible Asset policyと、`plan.journal`にあるtyped Plan metadata / reservation evidenceから`DailyTargetScope`を組み立てる。delivery adapterが旧TSVを併読したり、Account名やPlan表示Textからscopeを再構成したりしない。

## Household Report

Household ReportはすでにSpikeではない。

- domain / projection owner: `HKernel.Household.Report`
- rendering owner: `HKernel.Household.Report.Render`
- canonical Household composition entrypoint: `HKernel.Household.Application`
- TUI feature owner: `HKernel.Editor.TUI.Report`

```text
HouseholdState
  -> admitted Household Report inputs
  -> HKernel.Household.Report
  -> HouseholdReportSurface
  -> HKernel.Household.Report.Render
```

## Retained compatibility source

`accounts.tsv`、`plan.tsv`、`budget_alloc.tsv`、`cycle.tsv`、`config.tsv`、`daily_target_scope.tsv`、legacy Report manifestsは、current `h-kernel` canonical Household bootstrapの入力ではない。

それらが別engineのcompatibility、migration evidence、private repository historyとして残るかどうかは、このreader inventoryから推測しない。current application pathへ「念のため」併読を戻さない。

## 維持する境界

- exact Quantity / Commodityを保つ
- Account、Plan、Actual、Budgetのidentity / provenanceを失わない
- canonical sourceのprivate ownershipを変えない
- write capabilityからwriter authorityを推測しない
- `HouseholdWriteSnapshot`の同一observation boundaryを崩さない
- source-local failureをsilent fallbackへ変換しない
- generic source parser、generic repository/session、generic event frameworkを先回りして作らない
- current ownerが直接表現できる処理にcompatibility wrapperを増やさない
