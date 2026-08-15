# Household canonical source contract

ステータス: current architecture contract  
Owner: canonical Household source shape、source role boundary、engine-neutral semantic contract  
更新日: 2026-08-15

## 目的

private `household-ledger-data` repositoryのrootを、`h-kernel`と`bqn-ledger`が共有するcanonical Household rootとして扱う。

この文書は**現在のcanonical source shapeと、engineを越えて共有する意味の境界**を所有する。h-kernelが実際にどのsourceをどうadmitするかは[`HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md)、source別writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。

完了済みmigration手順や途中のcompatibility source配置はcurrent contractへ保存しない。過去の状態はGit履歴とmerged PRが所有する。

## Canonical root

現在のcanonical Household rootは次の8 sourceで構成する。

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

追加の`data/`や`config/`directoryをcanonical rootの内側に設けない。private repository root自体を`HouseholdRoot`とする。

## Source roles

### Facts and declarations

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transaction、posting、durable identity、explicit completion/correction relation
- `plan.journal`: future Plan、Plan identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered retained allocation movementとprovenance

### Domain policy

- `budget.toml`: retained physical current-policy source boundary。current Envelope definition/presentation、current Expense assignment compatibility、current Backing topologyを供給するが、それらを一つのsemantic ownerにはしない
- `household.toml`: household-specific policyとhistory。cycle、allocation Account、Plan destination、unassigned Account、effective-dated Envelope routing historyなどを所有する

`budget.toml`のcurrent Expense assignmentはhistorical Expense routing authorityではない。current configから過去のroutingを再構成しない。

### Application policy

- `report.toml`: typed Report query defaults、presentation、将来のnamed preset / ordered report setを所有する

`report.toml`はAccount classification、Envelope membership、canonical source filename、Actual/Plan/allocation factを所有しない。

### Notebook

- `issues.tsv`: user-authored household notebook。Issueから会計factやEnvelope policyを暗黙生成しない

## Engine-neutral semantic contract

canonical Householdが所有するのは、Journal / TOML / TSVの表面そのものだけではなく、それらからadmitされるsemantic coordinatesである。

```text
canonical Household source
  -> source-specific semantic admission
     -> h-kernel typed values
     -> bqn-ledger array-native values
```

- Haskellのconstructor、internal record shape、UI stateをsource contractへ保存しない
- BQNのarray shape、rank、command argument shape、compatibility manifestをsource contractへ保存しない
- Account identity、exact Quantity、Commodity、Plan identity、Actual identity、completion、reversal、allocation movement、provenance、policyなど、言語を越えて必要な意味をsource上で明示する
- 一方のengineが新しいsemantic coordinateへ未対応なら、推測やsilent ignoreをせずfail closedできる
- engineごとのcanonical fork、同期copy、dual representationを作らない
- reader compatibilityのために、先行engineのidentity / provenance contractを弱めない

`h-kernel`と`bqn-ledger`は同じsourceを異なる内部表現へ変換してよい。共有するのは内部データ構造ではなく、admission後に同じ意味へ到達することと、write後にその意味を失わないことである。

## Household root law

canonical delivery pathは、一つの`HouseholdRoot`からsource basenameを解決する。

```text
HouseholdRoot
  -> source-specific admission
  -> typed / array-native Household values and policies
  -> interaction and rendering
```

canonical basenameの対応はapplication ownerが一箇所で解決する。TUI navigation、Brick screen、Report preset、BQN command surfaceが`actual.journal`、`budget.toml`などのbasenameを独自に意味付けし直さない。

これはsource-specific parser ownershipをgeneric parserへ統合することを意味しない。各syntaxのadmission ownerは各engineのnamed ownerに残す。

explicit source pathを受け取るcompatibility / diagnostic entrypointが存在しても、それをcanonical application topologyの正本として扱わない。

## Report configuration

`report.toml`はcanonical HouseholdのReport application configである。

既存のtyped schemaがJournal-only Reportのquery defaultsとpresentationを所有する。Envelope、planned、cycle comparison、Daily Target、Issueなど新しいReport surfaceを追加する場合も、legacy execution argumentをgeneric arrayとして戻さず、typed requestとowner boundaryを先に確定する。

source filename、Household Account classification、Envelope membership、Actual/Plan/allocation factをReport presetへ埋め込まない。

## Retained compatibility evidence

`accounts.tsv`、`plan.tsv`、`budget_alloc.tsv`、`cycle.tsv`、`config.tsv`、`daily_target_scope.tsv`、legacy Report manifestsは、current h-kernel canonical bootstrapのsourceではない。

それらが別engineのcompatibilityやprivate repository historyとして残るかどうかは、このcanonical contractから推測しない。current applicationへ「念のため」併読を戻さない。

retained formatの意味を扱うcurrent compatibility moduleが存在する場合、その型・parser・testが現在の意味を所有する。完了済みmigration roadmapをcurrent architectureへ戻さない。

## Writer authority

canonical repositoryが一つであること、write capabilityが複数engineに存在すること、current operational writer authorityが一つであることを同一視しない。

source別authority、single-writer law、cutover gateは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。この文書はcanonical source shapeからwriter authorityを推測しない。

## Evolution law

canonical contractを将来変更する場合は、file数を減らすこと自体を目的にしない。

- fact、declaration、policy、application policy、notebookのownerを先に確認する
- unknown key、column、metadata、status、Commodity、relationを黙って捨てない
- identity、provenance、exact Quantity、Commodityを維持する
- source format migrationとwriter authority cutoverを同じchangeへ暗黙に混ぜない
- 一方のengineの内部表現をcanonical sourceへ持ち込まない
- conversionが必要ならsemantic parityを明示的に確認する
- 完了後は旧migration手順をcurrent documentへ保存せずGit履歴へ戻す

## Non-goals

- private source内容をpublic fixtureへ複製しない
- TUIのためにdomain ownershipをUIへ移さない
- Haskell internal shapeまたはBQN compatibility argument shapeをcanonical configへ保存しない
- engine別のcanonical source copyを作らない
- write capabilityからwriter authorityを推測しない
- current 8-source shapeを将来変更不能な永久形式として扱わない
