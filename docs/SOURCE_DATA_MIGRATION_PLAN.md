# 正規世帯sourceの所有権と移行

ステータス: アクティブ  
Owner: household source topology、source別writer authority、native source migration

## 1. 現在の配置

正規世帯sourceは`h-kernel`のGit履歴には置かず、user-ownedな別のprivate repositoryに置く。

```text
canonical location        separate private data repository
actual.journal writer     h-kernel editor
other retained writers    unchanged by Actual cutover
current readers           source-specific; bqn-ledger and h-kernel
public h-kernel           code, docs, synthetic evidence only
```

`h-kernel`は`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`からdirectoryを明示的に受け取る。private repositoryの名前やpathをcode、fixture、CIへ固定しない。

2026-08-06の明示的なcutoverにより、canonical `actual.journal`のwriter authorityだけを`h-kernel`へ移した。他のphysical sourceのwriter authorityは、この決定から推測して移さない。

## 2. Source ownership

現在のprivate source setには次の意味がある。

| basename | owner class | current writer/readers |
|---|---|---|
| `actual.journal` | Account declaration、Actual fact、completion evidence | h-kernel editor / both engines |
| `plan.journal` | native Plan fact | bqn-ledger / h-kernel |
| `accounts.tsv` | retained Account metadata | bqn-ledger / both engines |
| `plan.tsv` | retained Plan compatibility source | bqn-ledger |
| `budget_alloc.tsv` | ordered Budget movement fact | bqn-ledger / both engines |
| `budget.toml` | general Budget policy | user / h-kernel |
| `household.toml` | household-specific policy | user / h-kernel |
| `cycle.tsv`、`config.tsv` | retained compatibility policy/config | bqn-ledger / bqn-ledger |
| `daily_target_scope.tsv` | retained Daily Target selection and reservation declaration | bqn-ledger / both engines |
| `issues.tsv` | household notebook source | bqn-ledger / both engines |
| report manifest files | retained bqn-ledger execution configuration | bqn-ledger |

`h-kernel`のcurrent Household Reportは`config.tsv`、`cycle.tsv`、`plan.tsv`を読まない。Actual source selectionとcycle policyとPlan sourceは、それぞれ現在のnative ownerから得る。このcurrent reader状態は[`HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md)が実装目録として所有し、bqn-ledger側のreader/writer authorityやprivate sourceのretentionを変更しない。

同じphysical directoryにあることは、fact、policy、projection、execution configが同じdomain ownerまたはwriter authorityを持つことを意味しない。

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

`HKernel.Household.AccountProfile`は、この分類のsource-independentなsemantic contractを所有する。`AccountDeclaration`をidentity ownerとして再利用し、Budget policy evidence、Household policy evidence、unclassified metadataを別の値へ分ける。

`HKernel.Household.AccountProfile.TSV`はretained `accounts.tsv`の物理admissionを所有する。`role`と`currency`を既存smart constructorで`AccountDeclaration`へ変換し、残る全metadataをsemantic classifierへ渡す。Account identityと`AccountType`はActual Journal registryと双方向に照合する。Actual Journalがper-Account default Commodityを明示する場合はretained evidenceとの一致を要求し、省略している場合は矛盾ではなく未宣言として扱う。unknown key、適用外key、独立したinvalid座標は黙って失わない。

Household Report compositionはstable adapterを使用し、`AccountProfileTSVError`を既存`HouseholdSourceError`へ翻訳するだけである。Spike-local `AccountFact`、旧`parseAccounts`、metadata parser、role parser、type-only registry gateは削除済みである。private source format、`accounts.tsv` writer authority、target TOML生成はActual cutoverでは変更していない。

同じ`HKernel.Household.AccountProfile.TSV`は、admitted `Map Account RetainedAccountProfile`からAccount declarationだけを射影し、Account identityで明示的に並べたdeterministic `accounts.journal` shadow Textを生成する。生成するAccount directiveは`type:`を必ず持ち、retained Commodity evidenceがある場合は各Accountの`commodity:` metadataとして必ず明示する。global `commodity` directiveへ畳まない。

```text
retained accounts.tsv
  -> stable Account profile admission
  -> AccountDeclaration projection
  -> deterministic accounts.journal shadow Text
  -> parseAccountJournal
  -> exact declaration parity
```

exact parityはAccount集合、Account identity、`AccountType`、default Commodityを別座標として確認する。同じadmitted valueは同じTextを生成し、source row順序を変えても同じTextになる。生成Textを繰り返しparseしても同じ`AccountRegistry`を得る。optional default Commodityを持たないnative declarationもrendererで表現できる。

shadow parity errorはparse rejection件数または不一致座標の種類だけを保持し、Account名、source row、生成Textを保持しない。public testとCIは独立したsynthetic sourceだけを使う。private canonical sourceの追加rehearsalではshadowをfileへ保存せず、stdout、CI、PR、Issueへ内容を出さず、成功・失敗と秘密を含まない件数だけを扱う。

このshadow conversionはcurrent reader、Report composition、source selection、writerへ接続しない。`accounts.tsv`のretire、`accounts.journal`の正規source採用、Actual JournalのAccount directive削除、`accounts.tsv` writer authority移動は、それぞれ別の明示sliceでのみ行う。current compatibility parityとnative target parityを同一条件へ潰さない。

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
| `ACTUAL_JOURNAL_FILE` | Actual source selection | bqn-ledger application configとしてretain。h-kernel targetなし |

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

## 5. Source別のwriter law

private repositoryへの物理分離は、全sourceが同じwriterを持つことを意味しない。writer authorityはphysical sourceごとに明示する。

### 5.1 `actual.journal`

- canonical writerは`h-kernel` editorである。
- `h-kernel`と`bqn-ledger`はreaderとして同じsourceを読める。
- `bqn-ledger`のcanonical `actual.journal` write operationは使用しない。
- ordinary Actual addの日常入口は`tools/hk actual-add <ACTUAL_JOURNAL>`である。
- correctionは元factを編集せず、h-kernelのexplicit Actual reverseを使う。
- preview後にsourceが変化した場合はstaleとして拒否し、current sourceからやり直す。

activation、stop、rollbackの正規contractは[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

### 5.2 Other retained source

- Plan、Budget movement、Issue、retained metadata、policy、execution configのwriter authorityはActual cutoverで変更しない。
- 同じdirectoryにあることや、h-kernel editorにwrite capabilityが存在することからauthority移動を推測しない。
- source別cutoverは、それぞれ別のevidenceと作者承認を持つ明示sliceで行う。

### 5.3 Shared operational rules

- public checkout内に同期copyを作らない。
- source rowをrepository間でcopyまたはmergeするscriptを置かない。
- validation failure時は通常writeを止め、canonical directoryそのものを修復する。
- backupはcanonical Git treeとpublic Git履歴の外に置く。
- dual writeまたはalternating writerを行わない。

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

このtargetは方向であり、current compatibility fileを証拠なしに削除する許可ではない。Actual writer cutoverはsource format migrationではない。

## 7. Source migration law

- current fieldをfact、policy、projection、execution config、noteへ分類する。
- unknown key、column、metadata、status、Commodity、relationを黙って捨てない。
- Account名や残高からAccountType、Budget membership、liquidity、completionを推測しない。
- conversionはsource commitとconverter versionに対してdeterministicにする。
- Account identity、Actual、Plan、Budget、policy、ordering、provenanceのsemantic parityを観察する。
- source format migrationとwriter cutoverを同じsliceへ混ぜない。
- 一つのsourceのwriter cutoverから、別sourceのauthority移動を推測しない。

## 8. Source writer cutover gate

source別writer authorityは、少なくとも次を満たす明示PRでのみ移す。

1. 対象sourceに必要なoperation parity
2. mutation前previewとstrict complete-source admission
3. stale source rejection
4. atomic publishとpartial write不在
5. ignored backup、failure test、restore
6. duplicate identity、exact Quantity、Commodity別balance、provenanceの維持
7. synthetic sourceとprivate source copyを使った運用rehearsal
8. legacy writerとのsemantic comparison
9. dual writeを防ぐ運用変更
10. 作者による明示承認

### 8.1 Actual cutover completion

`actual.journal`については、次のevidenceとdecisionによってこのgateを通過した。

- public synthetic writer testによるsuccess、stale rejection、restore
- Actual candidate semantic comparison
- Actual reverse provenance contract
- private canonical sourceの明示的non-canonical copyによるpreview、commit、post-admission rehearsal
- rehearsal中のcanonical source、repository file、writer authority不変というsanitized operator evidence
- `tools/hk actual-add`から既存TUIへ渡すthin daily entrypoint
- `bqn-ledger` writerをcanonical `actual.journal`へ向けないsingle-user operation law
- 2026-08-06の作者明示承認

詳細は[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

この完了は、他sourceのgateを満たしたことを意味しない。

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

canonical Actual addの日常入口:

```sh
./tools/hk actual-add /absolute/path/to/private-ledger-data/actual.journal
```

Account declaration shadow rehearsalでは、stable Account admission後のprofileをmemory上でrender・parse-backし、shadow Textを保存または出力しない。failure時はAccount集合、AccountType、default Commodity、parse rejectionのどの種類かだけを報告し、値を含めない。
