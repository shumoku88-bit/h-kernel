# Household canonical target shape

ステータス: architecture target  
Owner: household canonical source shape、source role boundary、migration destination

## 目的

private `household-ledger-data` repositoryのrootを、`h-kernel`と`bqn-ledger`が共有するcanonical Household rootとして固定する。

この文書はmigration destinationとengine-neutralなsource contractを定義する。retained compatibility sourceの即時削除、reader cutover、writer cutoverを許可しない。それらはsemantic parityを確認した個別sliceで行う。

`h-kernel`は現在このtargetへのnative対応を先行して完成させる。`bqn-ledger`は同じcanonical source contractへ追従する。実装の進捗差から、engineごとに別のcanonical source、互換copy、同期用projectionを作らない。

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

## Engine-neutral canonical contract

canonical Householdが所有するのは、Journal / TOML / TSVの表面そのものだけではなく、それらからadmitされるsemantic coordinatesである。

```text
canonical Household source
  -> source-specific semantic admission
     -> h-kernel typed values
     -> bqn-ledger array-native values
```

- Haskellのconstructor、internal record shape、UI stateをsource contractへ保存しない
- BQNのarray shape、rank、command argument shape、compatibility manifestをsource contractへ保存しない
- Account identity、exact Quantity、Commodity、Plan identity、Actual identity、completion、reversal、Budget movement、provenance、policyなど、言語を越えて必要な意味をsource上で明示する
- 一方のengineが先に新しいsemantic coordinateへ対応した場合、もう一方は推測やsilent ignoreをせず、対応完了まではfail closedできる
- engineごとのcanonical fork、同期copy、dual representationを作らない
- reader compatibilityのために、先行engineのidentity / provenance contractを弱めない

`h-kernel`と`bqn-ledger`は同じsourceを異なる内部表現へ変換してよい。共有する必要があるのは内部データ構造ではなく、admission後に同じ意味へ到達することと、write後にその意味を失わないことである。

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
  -> typed / array-native Household values and policies
  -> interaction and rendering
```

application adapterはcanonical basenameを一箇所のHousehold root ownerから解決する。TUI navigationやBrick screen、BQN command surfaceが`actual.journal`、`budget.toml`などのbasenameを個別に意味付けし直さない。

この変更は、source-specific parser ownershipをgeneric parserへ戻すことを意味しない。各syntaxのadmission ownerは各engineのnamed moduleに残してよい。

## Report configuration

現在のh-kernel-native `report.toml` schemaをtargetのReport application configとして採用する。

既存schemaが所有するJournal-only Reportについては現在のtyped configをそのまま使う。legacy manifestにのみ存在するEnvelope、planned、cycle comparison、Daily Target、IssueなどのReportは、typed requestとowner boundaryを確定してから追加する。

legacy manifest rowをgeneric argument arrayとして`report.toml`へコピーしない。将来のBQN readerもlegacy execution argumentsへ戻るのではなく、同じ`report.toml` semantic contractをnativeにadmitする。

## Writer authority

canonical repositoryが一つであること、write capabilityが複数engineに存在すること、current operational writer authorityが一つであることを同一視しない。

- `actual.journal`: current canonical writer authorityはh-kernel editor
- `bqn-ledger`は同じcanonical write contractへ追従してwrite capabilityを実装できるが、capability追加だけではcurrent authorityを移動しない
- その他のsourceも、h-kernelまたはbqn-ledgerにwrite capabilityが存在することだけからauthorityを推測しない
- source-specific writer activation / cutoverは、complete-source admission、stale rejection、safe publication、identity / provenance parityを確認した明示sliceで行う
- engine間で意味の異なるdual writeや、互換sourceを介した二重書き込みを行わない

これにより、両engineを同じcanonical Householdへnative対応させながら、実装進捗差がある期間も一つのsource authorityを保つ。

## Migration order

完成形を先に固定し、移行は小さいsliceで行う。

1. target contractを固定する
2. `report.toml`をHousehold rootへ配置し、current h-kernel Report configとしてadmitする
3. `accounts.tsv -> accounts.journal` exact declaration parityとnative adoption
4. Budget movementを`budget.journal`へ移行
5. retained policy/config fieldsをtyped ownerへ移し、`config.tsv`、`cycle.tsv`をretire
6. Daily Target sourceをsemantic ownerへ分解する
7. legacy Report manifestの残りReportをtyped `report.toml`へ移す
8. compatibility sourceをreader/writer authorityごとにretireする
9. h-kernel側でcanonical Household v1のdaily operationを完成させる
10. bqn-ledgerを同じsemantic admission / write contractへnativeに追従させる
11. 実運用後、同じownerであることが確認できたtarget fileだけをさらに統合する

9と10は開発順序を固定するものではない。並行して進めてよい。ただし、一方の未完成を理由にcanonical sourceへcompatibility fieldやengine-specific projectionを追加しない。

ファイル数そのものを最小化することはこのmigrationの目的ではない。まずownershipを明瞭にし、その後に根拠のある引き算を行う。

## Non-goals

- private source内容をpublic fixtureへ複製しない
- source format migrationとwriter cutoverを同じsliceへ混ぜない
- TUIのためにdomain ownershipをUIへ移さない
- Haskell internal shapeまたはBQN compatibility argument shapeをcanonical configへ保存しない
- engine別のcanonical source copyを作らない
- target shapeを将来変更不能な永久形式として扱わない
