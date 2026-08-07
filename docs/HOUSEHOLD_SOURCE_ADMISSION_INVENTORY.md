# Household source admission inventory

ステータス: 現在状態のownership inventory  
更新日: 2026-08-07

## 目的

この文書は、現在のh-kernel Household Reportが実際に読むsourceと、そのadmission ownerを記録する。

private canonical directory全体の目録ではない。source format再設計、writer cutover、物理file削除は[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)が所有する。

## 現在のcomposition

```text
actual.journal
plan.journal
accounts.tsv
budget_alloc.tsv
budget.toml
household.toml
issues.tsv
daily_target_scope.tsv
  -> named admission owners
  -> HKernel.Spike.HouseholdReport
  -> HouseholdReportSurface
```

Household Report compositionは、source syntaxをまとめて扱うgeneric parserを持たない。各sourceを名前付きownerへ渡し、typed valueとsource-local errorを合成する。

### h-kernelが現在読まないretained source

次はprivate directoryに残り得るが、Household Reportの入力ではない。

- `config.tsv`
- `cycle.tsv`
- `plan.tsv`

`HKERNEL_LEDGER_DATA_DIR`利用時のActual sourceは`<directory>/actual.journal`で決まり、`config.tsv`の`ACTUAL_JOURNAL_FILE=actual.journal`を再確認しない。`cycle.tsv`のcycle座標は現在`household.toml`から読み、Planは`plan.journal`から読む。

これはprivate sourceの削除や、bqn-ledger側のreader/writer authority変更を意味しない。

## Inventory

| Source | 現在の入口 | typed output / role | ownership |
|---|---|---|---|
| `actual.journal` | `parseActualJournal` | Actual Journal、Account registry、completion evidence | stable `HKernel.Actual.Journal` |
| `plan.journal` | `parsePlanJournal` + Plan classification | future Plan、cycle anchor、outgoing commitment | stable `HKernel.Plan.Journal` |
| `accounts.tsv` | `admitRetainedAccountProfiles` | retained Account profile + Actual registry compatibility | stable `HKernel.Household.AccountProfile.TSV` |
| `budget_alloc.tsv` | `parseHouseholdBudgetMovements` | ordered Budget movement facts | stable `HKernel.Household.BudgetMovement.TSV` |
| `budget.toml` | `parseBudgetPolicy` | general Budget policy | stable `HKernel.Budget.Config` |
| `household.toml` | `parseHouseholdPolicy` | cycle、allocation、household-specific policy | stable `HKernel.Household.Config` |
| `issues.tsv` | `parseHouseholdIssues` | user-authored typed household issues | stable `HKernel.Household.Issue.TSV` |
| `daily_target_scope.tsv` | `parseDailyTargetScope` | Daily Target selection and reservation evidence | stable `HKernel.Household.DailyTarget.TSV` |

## `accounts.tsv`

一つのrowからAccount identity、`role`、`currency`とretained metadataを読む。stable admissionは`role`と`currency`を`AccountDeclaration`へ変換し、それ以外を`HKernel.Household.AccountProfile`へ渡す。unknown metadataを黙って捨てない。

registry gateは次を確認する。

- `accounts.tsv`の全Accountが`actual.journal`に宣言されている
- `actual.journal`の全Accountが`accounts.tsv`に存在する
- AccountTypeが一致する
- Actual Journalがper-Account default Commodityを明示する場合、retained evidenceと一致する

Actual側でdefault Commodityが省略されている場合は矛盾ではなく未宣言として扱う。

```text
accounts.tsv Text
  -> HKernel.Household.AccountProfile.TSV
  -> AccountDeclaration + retained metadata
  -> Actual Journal AccountRegistry compatibility parity
  -> Household Report composition
```

### declaration shadow

同じownerはAccount declarationだけのread-only shadowを生成できる。

```text
Map Account RetainedAccountProfile
  -> projectRetainedAccountDeclarations
  -> stable Account ordering
  -> renderRetainedAccountJournalShadow
  -> parseAccountJournal
  -> exact AccountDeclaration parity
```

shadowはfileへ保存せず、current reader、Report composition、writer、source selectionへ接続しない。`accounts.journal`のcanonical adoptionを意味しない。

## `budget_alloc.tsv`

`HKernel.Household.BudgetMovement.TSV`がdate、memo、from/to Account、exact quantity、Commodityを`[HouseholdBudgetMovement]`へadmitする。

```text
budget_alloc.tsv
  -> [HouseholdBudgetMovement]
       -> Entitlement history
       -> Household Backing
```

EntitlementとBackingは同じmovement factを別々に解釈する。compositionはTSV列を再解釈しない。

## `budget.toml` / `household.toml`

一般Budget policyとhousehold-specific coordinateを分けて読む。

```text
budget.toml
  -> BudgetPolicy
household.toml + BudgetPolicy
  -> HouseholdPolicy
```

`household.toml`は現在、income-anchor cycleとHousehold envelope coordinatesを所有する。旧`cycle.tsv`をReport compositionへ併読して同期しない。

## `plan.journal`

Plan Journalはcurrent Plan sourceである。Household ReportはActual JournalとのAccount declaration parityを確認した後、incoming cycle anchorとoutgoing commitmentをtypedに分類する。

legacy `plan.tsv`はHousehold Report入力ではない。

## `issues.tsv`

`HKernel.Household.Issue.TSV`がstrict headerとrowを`[HouseholdIssue]`へadmitする。Issue identity、status、recorded date、category、title、exact Amount、detailsを保持し、due dateを推測しない。

Issueは会計factやBudget policyを暗黙生成しない。

## `daily_target_scope.tsv`

`HKernel.Household.DailyTarget.TSV`がeligible Asset selectionとPlan reservation evidenceをadmitする。Account registryとPlan identityを明示的に検証し、reservation amountやCommodityを推測しない。

このsourceをderived projectionへ置き換える場合は、別sliceで同じselectionとreservation evidenceを再生成できることを証明する。

## 現在のmigration boundary

Account declaration shadow conversionは存在するが、current source adoptionとは分離する。

次のsource migration decisionでは、少なくとも次を別々に扱う。

1. semantic parityの観察
2. native source adoption
3. current reader切替
4. writer cutover
5. retained source retirement

一つの成功から別sourceのwriter authority移動を推測しない。

## 維持する境界

- external private sourceのpath、内容、writer authorityを変更しない
- bqn-ledgerのreader/writer authorityをこのinventoryから変更しない
- current Report値と表示を変更しない
- private rowを丸ごとdiagnosticへ保持しない
- admission移動とsource format redesignを同じsliceへ混ぜない
- generic TSV frameworkを先に作らない
