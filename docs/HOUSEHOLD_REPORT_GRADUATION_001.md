# Household Report graduation 001

ステータス: 実装検証中  
更新日: 2026-08-11

## 目的

production deliveryが恒常的に依存するHousehold Report経路を、古い`Spike`配置から現在のstable ownershipへ一致させる。

これは行数削減を目的とした一般的な共通化ではない。旧Spike境界が成立した当時の条件と、現在のcanonical typed admissionを比較し、すでに役目を終えたraw compatibility compositionだけを引く。

## 観察

旧`HKernel.Spike.HouseholdReport`には二つの入口が同居していた。

1. already admittedなtyped valueからReport surfaceを作るpure path
2. retained TSV/TOML/Journal textをReport module自身がadmitするraw compatibility path

現在のproduction `HKernel.Household.Application`は1だけを使い、canonical Household admissionから`HouseholdState`を構成してReportへ渡している。2の直接callerはproduction deliveryには残っていなかった。

旧`HOUSEHOLD_REPORT_SPIKE_REVIEW.md`は、`accounts.tsv`、`budget_alloc.tsv`、`daily_target_scope.tsv`をReport compositionが直接読む時期の卒業条件を記録していた。そのsource topologyは後続のcanonical Household migrationで変化している。

## 卒業後のowner

```text
canonical Household sources
  -> HKernel.Household.Application
       -> typed HouseholdState
       -> HKernel.Household.Report
            -> HKernel.Household.BudgetObservation
            -> stable Plan / Actual / Budget / Backing / DailyTarget owners
       -> HKernel.Household.Report.Render
  -> CLI / TUI delivery
```

- `HKernel.Household.Report`: already admitted valuesのpure composition
- `HKernel.Household.BudgetObservation`: ordered Budget movementからConsumption / Entitlement / Remainingを揃えるpure owner
- `HKernel.Household.Report.Render`: presentationのみ
- `HKernel.Household.Application`: canonical source IO、typed admission、HouseholdState、write snapshot、Report bootstrap

pure Report群は`h-kernel-household`、IO Applicationは`h-kernel-household-application`へ分離する。

## 引いたもの

- `spike-src/`
- `h-kernel-spike-household-report` Cabal component
- production `HKernel.Spike.*` namespace
- `buildHouseholdReportSurfaceFromPlanJournal` raw compatibility entrypoint
- Report module内のretained Account/Budget movement/Daily Target TSV parser wiring
- raw compatibility entrypoint専用のsource-local error translatorsとregistry gate

retained compatibility parser自体や、別sourceのreader/writer authorityはこの変更から削除・移動しない。

## Test migration

旧`HouseholdReportSpec`はReport計算/表示契約とretained source compatibility admissionを一つのfixtureで検査していた。

卒業後はReport契約をcurrent canonical source shapeへ載せ替える。canonical 8-source admission、filesystem loading、source disagreement、native Plan metadata fail-closed、writer snapshot/rollback等は既存`CanonicalHouseholdSpec`とsource-specific contract testsが引き続き所有する。

Report testでは次の意味を維持する。

- current / previous income-anchor cycle
- aligned elapsed comparison
- Plan completionとhorizon classification
- native Budget movement -> entitlement
- Actual Expense -> consumption
- current-cycle open Plan reserve/headroom
- explicit backing policy
- native Daily Target asset/reservation
- Issue rendering
- unavailable comparisonの局所化
- invalid Account role / Plan role / completion / reservationのfail-closed

## 境界

- exact arithmeticを変えない
- Account / Plan / Actual identityを推測しない
- provenance/completionはtyped evidenceから扱う
- source admissionをReport calculationへ戻さない
- renderingへdomain calculationを移さない
- application IOをpure Household libraryへ混ぜない
- generic Report frameworkを導入しない
- writer authorityをmodule placementから推測しない
- private canonical sourceをpublic fixtureへ転用しない

## 行数について

このsliceの価値はLOC削減量では評価しない。mainとの最終diffではdocs/testを含めてnet subtractionになるが、重要なのは古いcompatibility ownershipを一つ消し、production依存とmodule/component vocabularyを一致させることである。

## Qualification

merge判断前に少なくとも次を確認する。

1. normal full CI success
2. final diffにtemporary workflow/scriptがない
3. `spike-src/`とproduction `HKernel.Spike.*`参照がない
4. Cabal component dependency directionがpure Household -> Application -> deliveryを維持する
5. rewritten HouseholdReportSpecがcurrent canonical sourceでreport意味を検証する
6. private source / writer authority / exact arithmetic / identity / provenanceの変更がない
