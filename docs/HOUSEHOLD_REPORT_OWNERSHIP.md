# Household Report ownership

ステータス: アクティブなstable boundary  
更新日: 2026-08-11

## 目的

Household Report の現在のownerと依存方向を記録する。旧 `Spike` placement は、canonical Household admission がstable ownerへ移る前の暫定境界だった。現在のproduction pathはその条件を満たしたため、Report compositionをstable Household componentへ卒業させる。

## 現在の構成

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

### `HKernel.Household.Report`

already admittedなtyped valueだけを受け取り、次を一つのread-only `HouseholdReportSurface`へ合成する。

- current / previous cycle observation
- open Plan とcompletion evidence
- Budget observation
- Household Backing
- Daily Target
- Household Issues

物理source parser、filesystem IO、writer authorityを所有しない。

### `HKernel.Household.BudgetObservation`

ordered `HouseholdBudgetMovement` とvalidated Household policyを、Consumption / Entitlement / Remainingへ揃えるpure ownerである。旧 `HKernel.Spike.HouseholdConsumption` の責任をそのままstable Household vocabularyへ移したもので、generic accounting frameworkは導入しない。

### `HKernel.Household.Report.Render`

already typedなReport surfaceのpresentationだけを所有する。stable `HKernel.Render` / `HKernel.Render.TerminalStyle`を再利用し、accounting calculationやsource admissionを再実装しない。

### `HKernel.Household.Application`

canonical 8-source rootのIO bootstrap、typed admission、`HouseholdState`、write snapshotを所有する。pure Household libraryへIOを混ぜないため、Cabal component `h-kernel-household-application` に分離する。

## 退役した暫定境界

旧 `buildHouseholdReportSurfaceFromPlanJournal` は、`accounts.tsv`、`budget_alloc.tsv`、`daily_target_scope.tsv` 等のretained compatibility sourceをReport moduleから直接admitしていた。current production deliveryはすでにこの入口を使用せず、canonical `HouseholdState`からtyped report calculationへ進む。

そのため、Report compositionから旧raw compatibility入口とsource-local parser wiringを削除する。retained compatibility parser自体の存在や、別repositoryのreader/writer authorityをこの決定から変更しない。

## 維持する境界

- exact arithmeticを維持する
- Account / Plan / Actual identityを推測しない
- provenanceとcompletion relationをtyped evidenceから扱う
- source admissionとReport calculationを混ぜない
- rendererへdomain calculationを移さない
- application IOをpure Household libraryへ混ぜない
- private canonical sourceをpublic testやdiagnosticへ持ち込まない
- writer authorityはReportのmodule placementから推測しない

## 教材としての意味

`Spike`という名前は「まだ意味が確定していない実験」を示す。production CLI/TUIが恒常的に依存し、canonical typed admissionからReportを生成する現在の構造を`Spike`と呼び続けると、実際のownershipを誤って教える。

今回の卒業は抽象化の追加ではなく、すでに成立しているownerへ名前とcomponent配置を一致させる整理である。
