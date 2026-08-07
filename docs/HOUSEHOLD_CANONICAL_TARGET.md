# Household canonical target shape

ステータス: architecture target  
Owner: household canonical source shape、source role boundary、migration destination

## 目的

private `household-ledger-data` repositoryのrootを、h-kernelが最終的に扱うHousehold rootとして固定する。

この文書はmigration destinationを定義する。legacy sourceはsemantic parityを確認した個別sliceで移し、役目を終えた時点で削除する。

## Target root

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

追加の`data/`や`config/`directoryをcanonical rootの内側に設けない。private repository root自体をHousehold rootとする。

## Source roles

### Facts and declarations

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transaction、posting、durable identity、explicit completion/correction relation
- `plan.journal`: future Plan、Plan identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered Budget decision/movementとprovenance

### Domain policy

- `budget.toml`: general Budget policy。Envelope、pacing、backing pool、Expense assignmentを所有する
- `household.toml`: household-specific policy。cycle、allocation Account、Plan destination、unassigned Accountなどを所有する

### Application policy

- `report.toml`: typed Report query defaults、presentation、将来のnamed preset / ordered report setを所有する

`report.toml`はAccount classification、Envelope membership、canonical source filename、Actual/Plan/Budget factを所有しない。

### Notebook

- `issues.tsv`: user-authored household notebook。Issueから会計factやBudget policyを暗黙生成しない

## Current-to-target mapping

| Current source | Target |
|---|---|
| `accounts.tsv` | `accounts.journal`へsemantic migration後retire |
| `actual.journal` | retain。Account declarationの最終分離は別slice |
| `plan.journal` | retain |
| `plan.tsv` | native Plan parity後retire |
| `budget_alloc.tsv` | `budget.journal`へsemantic migration後retire |
| `budget.toml` | retain |
| `household.toml` | retain |
| `cycle.tsv` | `household.toml` parity後retire |
| `config.tsv` | typed ownersへ分解後retire |
| `daily_target_scope.tsv` | stable Household policy / Plan reservation evidence / derivable selectionへ分類後retire |
| `report_manifests.tsv` | `report.toml` migration後retire |
| `report_all_human.tsv` | `report.toml` migration後retire |
| `report_all_compact.tsv` | `report.toml` migration後retire |
| `issues.tsv` | retain |

## Household root law

TUI、CLI、Report compositionは最終的に個別source pathをapplication entrypointから受け取らない。

```text
HouseholdRoot
  -> source-specific admission
  -> typed Household / policies / report config
  -> interaction and rendering
```

application adapterはcanonical basenameを一箇所のHousehold root ownerから解決する。TUI navigationやBrick screenが`actual.journal`、`budget.toml`などのbasenameを個別に組み立てない。

この変更は、source-specific parser ownershipをgeneric parserへ戻すことを意味しない。各syntaxのadmission ownerは現在のnamed moduleに残す。

## Report configuration

h-kernel-native `report.toml` schemaをtargetのReport application configとして採用する。

既存schemaが所有するJournal-only Reportについては現在のtyped configをそのまま使う。legacy manifestにのみ存在するEnvelope、planned、cycle comparison、Daily Target、IssueなどのReportは、typed requestとowner boundaryを確定してから追加する。

legacy manifest rowをgeneric argument arrayとして`report.toml`へコピーしない。

## Writer

`h-kernel`を全target sourceのreader/writerとして完成させる。`bqn-ledger`は正規データと互換性がないため運用しない。

- `actual.journal`はh-kernel editorが読み書きする
- その他のsourceはh-kernel operationをsourceごとに実装・検証する
- 未実装operationは旧applicationへfallbackしない
- target fileを作るだけで完成扱いにせず、previewとsafe publicationを確認する
- dual writeを行わない

## Migration order

完成形を先に固定し、移行は小さいsliceで行う。

1. target contractを固定する
2. `report.toml`をHousehold rootへ配置し、current h-kernel Report configとしてadmitする
3. `accounts.tsv -> accounts.journal` exact declaration parityとnative adoption
4. Budget movementを`budget.journal`へ移行
5. retained policy/config fieldsをtyped ownerへ移し、`config.tsv`、`cycle.tsv`をretire
6. Daily Target sourceをsemantic ownerへ分解する
7. legacy Report manifestの残りReportをtyped `report.toml`へ移す
8. legacy sourceをsemantic parity確認後にretireする
9. 実運用後、同じownerであることが確認できたtarget fileだけをさらに統合する

ファイル数そのものを最小化することはこのmigrationの目的ではない。まずownershipを明瞭にし、その後に根拠のある引き算を行う。

## Non-goals

- private source内容をpublic fixtureへ複製しない
- source format migrationと無関係なUI変更を同じsliceへ混ぜない
- TUIのためにdomain ownershipをUIへ移さない
- BQN compatibility argument shapeを新しいcanonical configへ保存しない
- target shapeを将来変更不能な永久形式として扱わない
