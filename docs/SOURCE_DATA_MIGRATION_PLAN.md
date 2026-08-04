# 正規世帯sourceの所有権と移行

ステータス: アクティブ  
Owner: household source topology、writer authority、native source migration

## 1. 現在の配置

正規世帯sourceは`h-kernel`のGit履歴には置かず、user-ownedな別のprivate repositoryに置く。

```text
canonical location  separate private data repository
current writer      bqn-ledger editor
current readers     bqn-ledger and h-kernel
future writer       h-kernel editor after explicit cutover
public h-kernel     code, docs, synthetic evidence only
```

`h-kernel`は`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`からdirectoryを明示的に受け取る。private repositoryの名前やpathをcode、fixture、CIへ固定しない。

## 2. Source ownership

現在のprivate source setには次の意味がある。

| basename | owner class | current writer/readers |
|---|---|---|
| `actual.journal` | Account declaration、Actual fact、completion evidence | bqn-ledger / both engines |
| `plan.journal` | native Plan fact | bqn-ledger / h-kernel |
| `accounts.tsv` | retained Account metadata | bqn-ledger / both engines |
| `plan.tsv` | retained Plan compatibility source | bqn-ledger |
| `budget_alloc.tsv` | ordered Budget movement fact | bqn-ledger / both engines |
| `budget.toml` | general Budget policy | user / h-kernel |
| `household.toml` | household-specific policy | user / h-kernel |
| `cycle.tsv`、`config.tsv` | retained compatibility policy/config | bqn-ledger / both engines |
| `daily_target_scope.tsv` | retained Daily Target selection and reservation declaration | bqn-ledger / both engines |
| `issues.tsv` | household notebook source | bqn-ledger / both engines |
| report manifest files | retained bqn-ledger execution configuration | bqn-ledger |

同じphysical directoryにあることは、fact、policy、projection、execution configが同じdomain ownerを持つことを意味しない。

## 3. Retained sourceのfield分類

物理fileを先に統合せず、各fieldをDeclaration、Fact、Budget policy、Household policy、Report application config、Application config、Derived projection、Noteへ分類する。同じrowが複数の意味を含む場合はdeterministic conversionでtyped ownerへ分け、複数ownerが同じ意味を重複保持しない。

### `accounts.tsv`

| field / key | 意味 | target owner |
|---|---|---|
| Account名 | stable Account identity | `accounts.journal` |
| `role` | `AccountType` | `accounts.journal` |
| `currency` | Accountのdefault Commodity evidence | `accounts.journal` |
| `type=liquid/savings/invest` | Household asset class、liquidity、purpose | Household policy |
| Asset rowの`budget` | Plan destination relation | Household policy |
| Expense rowの`budget` | Envelope membership | Budget policy |
| Budget Account rowの`budget` | Envelopeとallocation Accountのrelation | Household policy |
| `kind=opening/unassigned/spent/envelope` | Budget structural Account role | Budget/Household policy。exact ownerをcontractで確定する |
| `envelope_role=dynamic/execution` | user spendingとplanned executionの区別 | Household policy |
| `budget_group=daily/flex/reserve` | grouping、order、reserve distinction | Household policy。`pacing`と同一視しない |
| `fixed` | fixed obligation classification | Household policy |
| `spend_class=fixed/variable` | spending classification | Household policy |

`currency`はapplicationの`DEFAULT_CURRENCY`とは別である。Account名prefixからrole、Budget membership、liquidityを推測せず、unknown keyを黙って破棄しない。

`HKernel.Household.AccountProfile`は、この分類のsource-independentなsynthetic contractを所有する。`AccountDeclaration`をidentity ownerとして再利用し、Budget policy evidence、Household policy evidence、unclassified metadataを別の値へ分ける。physical `accounts.tsv` admissionとActual Journal parityは後続sliceである。

### `cycle.tsv`

| field | 意味 | target |
|---|---|---|
| `mode=incomeAnchor` | cycle algorithm selection | `household.toml`の`cycle.mode` |
| `income_account` | cycle anchor Account | `household.toml`の`cycle.income-account` |

`household.toml`とのsemantic parityを確認した後にretireし、二sourceを恒久同期しない。

### `config.tsv`

| key | classification | target |
|---|---|---|
| `HOUSEHOLD_GROUP_LIFE`、`HOUSEHOLD_GROUP_RESERVE` | Household group membership | Household policy |
| `HOUSEHOLD_GROUP_ORDER` | group order | Household policy。domain orderかpresentationかをtestで確定する |
| `BUDGET_PREFIX` | prefix-based compatibility inference | explicit admission後にretire |
| `BUDGET_ID_OPENING`、`BUDGET_ID_SPENT` | Budget structural Account reference | Budget/Household policy |
| `BUDGET_ID_UNASSIGNED` | unassigned relationまたはcompatibility sentinel | Household policy |
| `POLICY_BUDGET_STYLE`、`POLICY_RISK_STYLE`、`POLICY_INCOME_CADENCE` | Household policy selection | Household policy。未使用labelなら明記してretire |
| `EXECUTION_PLANNED_PAYMENTS_ENVELOPE` | planned payment execution policy | Household policy |
| `DEFAULT_CURRENCY` | command/editor input default | Application config。既存Amountへ暗黙適用しない |
| `ACTUAL_JOURNAL_FILE` | Actual source selection | `HKernel.Application.Config` |

一つのTOML tableへ機械変換せず、Household policy、application config、役目を終えたcompatibility keyへ分ける。

### `daily_target_scope.tsv`

| row / field | current meaning | future decision |
|---|---|---|
| `kind=asset` | long-lived eligible Asset policy | Household policyへ移し、`AccountRegistry`で検証 |
| `kind=obligation` + `plan_id` | cycle-varying Plan obligation selection | explicit selectionとして残すか、open Planからderiveするかをparity contractで決める |
| `scope_id` | policy/selection identity | row kindに応じたowner |
| `account_key` | selected Asset Account | Household policy |
| `excluded_amount` + `currency` + `reservation_ref` | explicit `PlanReservationDeclaration` | Plan reservation evidence owner。partial coordinateを拒否する |

obligation rowは現在derived projectionではなく、open committed Planへ解決される明示declarationである。deriveへ変える前に同じobligation集合とreservation evidenceを再生成できることを証明する。

### Legacy Report TSV

| coordinate | classification | target |
|---|---|---|
| `key` | Report kind / named preset | typed Report request / `report.toml` |
| `surface=human/compact` | presentation preset | Report application config |
| Commodity、date、month、count、comparison mode | Report query coordinate/default | typed Report query / `report.toml` |
| source filename | source selection | Application config。Report presetへ埋め込まない |
| trailing Account list | Household semantic scopeまたはReport-only filter | Reportごとのownerへ分類 |
| manifest filename | legacy set selection | named Report setとして価値がなければretire |

legacy rowをgeneric argument arrayとしてTOMLへ写さない。typed Report entrypoint、Household scope、source selectionが揃ったReportから移す。

## 4. Private/public boundary

private repositoryには正確な日付、数量、Account、Transaction、Plan、policy、noteが含まれる。その現在値だけでなく、commit、branch、Pull Request、Issue、backup、recovery artifactも公開しない。

public repositoryのexampleとtest corpusは独立したsynthetic dataだけを使う。private sourceを匿名化、丸め、日付shiftしてfixtureへ転用しない。CIはprivate repositoryをcheckoutせず、secretやtokenで接続しない。

詳細は[`../SECURITY.md`](../SECURITY.md)が所有する。

## 5. 一人のwriter

- `bqn-ledger`の`LEDGER_DATA_DIR`はprivate canonical directoryを指す。
- `h-kernel`は同じdirectoryをread-onlyでadmitする。
- public checkout内に同期copyを作らない。
- source rowをrepository間でcopyまたはmergeするscriptを置かない。
- validation failure時は通常writeを止め、canonical directoryそのものを修復する。
- backupはcanonical Git treeとpublic Git履歴の外に置く。

private repositoryへの物理分離はwriter authorityの移動ではない。明示的なcutoverまでは`bqn-ledger`がwriterである。

## 6. h-kernel-native target

目標source shapeは小さく保つ。

```text
accounts.journal
actual.journal
plans.journal
budget.journal
household.toml
issues.tsv
```

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transactionと明示的completion relation
- `plans.journal`: 将来commitment、identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered Budget decisionとprovenance
- `household.toml`: stable household policy
- `issues.tsv`: 会計factを暗黙生成しないnotebook source

このtargetは方向であり、current compatibility fileを証拠なしに削除する許可ではない。

## 7. Source migration law

- current fieldをfact、policy、projection、execution config、noteへ分類する。
- unknown key、column、metadata、status、Commodity、relationを黙って捨てない。
- Account名や残高からAccountType、Budget membership、liquidity、completionを推測しない。
- conversionはsource commitとconverter versionに対してdeterministicにする。
- Account identity、Actual、Plan、Budget、policy、ordering、provenanceのsemantic parityを観察する。
- source format migrationとwriter cutoverを同じsliceへ混ぜない。

## 8. h-kernel editor cutover gate

writer authorityは、少なくとも次を満たす明示PRでのみ移す。

1. 必要なAccount、Actual、Plan、Budget、policy、notebook operationのparity
2. mutation前previewとstrict complete-source admission
3. stale source rejection
4. atomic publishとpartial write不在
5. ignored backup、failure test、restore
6. duplicate identity、exact Quantity、Commodity別balance、provenanceの維持
7. synthetic sourceとprivate source copyを使った運用rehearsal
8. bqn-ledgerとのsemantic comparison
9. dual writeを防ぐ運用変更
10. 作者による明示承認

cutover完了までは`bqn-ledger`が唯一のwriterであり、`h-kernel` editorの試験はsynthetic sourceまたは明示的な非正規copyを対象にする。

## 9. 検証

public codeの標準検証:

```sh
cabal build all
cabal test all
cabal run repository-audit
sh ./report-verify --fixture
sh ./report-verify --corpus
```

private canonical sourceへ影響する変更では、内容を出力せず明示directoryで追加検証する。

```sh
HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data ./report all >/dev/null
```
