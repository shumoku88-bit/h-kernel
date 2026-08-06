# h-kernel

型で不正な状態を減らし、exact multi-commodity arithmeticを保つ、Haskellの複式簿記・家計観察kernelです。

実用品を作りながら、型、pure transformation、ADT、lawful aggregation、module ownership、明示的なeffect boundaryをコードから読めることを重視します。

## Current shape

```text
private household source
  -> named source admission
  -> exact accounting / policy / projection
  -> Report and Household surfaces

edit intent
  -> pure candidate
  -> strict complete-source admission
  -> preview
  -> explicit safe publication effect
```

主なcomponentは次です。

- `h-kernel`: Account、Money、Ledger、Journal、Actual、Plan、Budget、Engine、Report
- `h-kernel-household`: Account profile admission、Household policy、Daily Target、Backing、Budget movement、Issue admission
- `h-kernel-editor`: edit intent、candidate preparation、source placement、safe writer
- `h-kernel-spike-household-report`: provisional Household Report composition
- report CLI、editor CLI、Actual add TUI、daily command hub

全体の編成と未決定案は[`docs/CODE_MAP_AND_DESIGN_SKETCH.md`](docs/CODE_MAP_AND_DESIGN_SKETCH.md)にあります。

## Current features

- `Scientific`によるexact decimal Quantity。`Double`は使わない
- runtimeで検証される任意のCommodity
- Commodityごとに独立したdouble-entry balance validation
- invalidまたはunbalancedな`Transaction`を作れないAPI
- explicit `AccountType`、optional default Commodity、`AccountRegistry`
- undeclared Accountとdefault Commodity conflictをsource coordinate付きで拒否
- unresolved includeをvalidated `Journal`と混同しない`JournalDocument`
- relative include graphを読むtyped loaderとfinite cycle error
- line coordinateとreasonを保持するpure Journal parser
- typed `DateRange`とpure Report projections
- Trial Balance、Balance Sheet、Profit and Loss、Daily Flow、Monthly Accounts、Recent Transactions、Cycle Accounts
- external typed policyから作るEnvelope Budget
- Household policy、Daily Target、Household Backing、unassigned Budget evidence、Plan reserve observation
- raw textとstyled textを分けるCJK-aware terminal rendering
- Actual、Account、Budget movement、Issue、Plan lifecycleのtyped editor operations
- preview、strict complete-source admission、stale rejection、backup、atomic publication、post-admission、restore-capable failure
- report、actual-add/transfer、actual-multi、actual-reverse、account、plan、budget、issue、edit、check、helpをまとめるthin `tools/hk`

## Daily command hub

日常入口は`tools/hk`です。引数なし（TTY）で起動した場合、対話型メニューが開きます。

```bash
# 対話型日常メニューを起動 (TTY環境)
./tools/hk

# --base DIR で private ledger directory を明示指定
./tools/hk --base /path/to/private-ledger-data

# report commandへ委譲
./tools/hk report bs
./tools/hk report all

# ordinary Actual add / transfer (2-posting add) TUIを起動
./tools/hk actual-add [/absolute/path/to/actual.journal]

# Actual multi-posting (append) CLIへ委譲
./tools/hk actual-multi [/absolute/path/to/actual.journal] 2026-08-06 "multi posting" Acct1 -100 JPY Acct2 100 JPY

# explicit Actual reversal intentを既存Editor CLIへ渡す
# defaultはpreview。publication時だけ--commitを付ける
./tools/hk actual-reverse \
  [--commit] \
  [/absolute/path/to/actual.journal] \
  NEW-EVENT-ID \
  TARGET-EVENT-ID \
  2026-08-06 \
  correction-description

# Account, Plan, Budget, Issue CLIへ委譲
./tools/hk account [/absolute/path/to/actual.journal] Assets:Saving asset JPY
./tools/hk plan add ...
./tools/hk budget ...
./tools/hk issue ...

# editor CLIまたはファイル編集へ委譲
./tools/hk edit ...

# build、test、repository ownership audit
./tools/hk check

# direct command surface
./tools/hk help
```

`tools/hk`は会計計算、Report rendering、editor admission、source mutation、audit ruleを再実装しません。`--base DIR`、`HKERNEL_LEDGER_DATA_DIR`、または`ledger-data.local`から private source directory を解決し、既存の Haskell CLI/TUI Executable へ routing します。

## Build and verification

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
```

同じ標準検証は次でも実行できます。

```bash
./tools/hk check
```

GitHub ActionsはGHC 9.10.3、9.12.4、9.14.1でbuildとtestを実行します。public CIはprivate canonical sourceをcheckoutしません。

`examples/sample.journal`と`tests/corpus/synthetic-v1/`は、最初から独立して作ったsynthetic dataです。private sourceを匿名化、丸め、日付shiftしてfixtureへ転用しません。公開境界は[`SECURITY.md`](SECURITY.md)を参照してください。

## Report launcher

最適化済みreport binaryを準備します。

```bash
sh ./report-build
```

`report-build`はGit管理外の`.report-bin/`へbinaryを配置し、`./report`はそのbinaryを直接起動します。

```bash
./report
./report bs
./report all
./report-snapshot
./report-real-snapshot
```

性能計測:

```bash
sh ./report-benchmark bs
RUNS=10 sh ./report-benchmark daily
```

Cabalから個別に実行する例:

```bash
cabal run exe:h-kernel -- examples/sample.journal check
cabal run exe:h-kernel -- examples/sample.journal all 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal trial-balance 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal balance-sheet 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal profit-and-loss 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal daily-flow 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal monthly-accounts 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal recent-transactions 2026-01-31
```

## External canonical household source

canonical household sourceは、public `h-kernel` repositoryではなくuser-owned private repositoryに置きます。

`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`でdirectoryを明示できます。

```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
./tools/hk report all
./tools/hk actual-add "$HKERNEL_LEDGER_DATA_DIR/actual.journal"
```

`ledger-data.local`にはprivate data directoryのpathを一行で書きます。このfileはGit管理しません。

`actual.journal`のcanonical writerは、2026-08-06の明示的なcutover contractにより`h-kernel` editorへ移る。`bqn-ledger`はreaderまたはReport engineとして使えるが、canonical `actual.journal`を変更するoperationには使わない。

```text
canonical actual.journal writer = h-kernel editor
bqn-ledger actual write          = not used
other source writer authority    = unchanged by this cutover
```

single-user operationのためcross-process shared lockは必須にしません。writerを切り替えるときは旧operationを終え、new editorでlatest sourceを読み直します。preview後にsourceが変化した場合はstaleとして拒否し、current sourceからpreviewをやり直します。

Actual writer cutoverの決定、activation、stop、rollbackは[`docs/ACTUAL_WRITER_CUTOVER_001.md`](docs/ACTUAL_WRITER_CUTOVER_001.md)が所有する。editorの現在地は[`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md)、source topologyと他sourceのwriter authorityは[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)が所有します。

private source、backup、temporary file、recovery workspace、generated report、local pathをpublic Gitへcommitしません。

## Journal format

Accountの意味は名前から推測せず、`account` directiveで宣言します。

```journal
account wallet:cash
    type: asset
    commodity: JPY

account living:food
    type: expense
    commodity: JPY

2026-08-01 Buy food
    living:food  1000 JPY
    wallet:cash
```

- `type:`と`commodity:`の順序に意味はない
- default Commodityを持たないmulti-commodity Accountも宣言できる
- Postingが使うAccountはすべてRegistryへ解決される
- explicit QuantityにはCommodityが必要
- 一Transactionにつき一PostingだけQuantityを省略してbalance amountを推論できる
- 異なるCommodityは互いに相殺しない

`include`はpure parserでtyped referenceとして保持し、IO loaderがincludeを書いたfileのdirectoryを基準に再帰解決します。

```journal
include accounts.journal
include transactions/2026.journal
```

unresolved includeを無視したpartial `Journal`は生成しません。cycleはclosed include pathを持つtyped `LoadError`として停止します。

## Actual reversal contract

Actual reversalは元Transactionを変更または削除せず、新しいinverse Transactionをappendします。

```journal
YYYY-MM-DD reversal description
  ; event-id: NEW-REVERSAL-ID
  ; reverses: TARGET-ACTUAL-ID
  account:a  INVERSE-AMOUNT COMMODITY
  account:b  INVERSE-AMOUNT COMMODITY
```

new durable identityとexplicit target relationを要求し、unknown target、self-reference、duplicate direct reversalを拒否します。日常入口は`tools/hk actual-reverse [--commit] <ACTUAL_JOURNAL> <NEW_EVENT_ID> <TARGET_EVENT_ID> <YYYY-MM-DD> <DESCRIPTION...>`です。専用selectorまたはTUIはまだなく、target identityは明示的に渡します。詳細は[`docs/ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](docs/ACTUAL_REVERSE_PROVENANCE_DECISION_001.md)にあります。

## Budget and Household observations

Envelope membershipはTransaction factではなくexternal policyです。Account名やIncome Accountの特別扱いから推測しません。

main Budget ownerは少なくとも次を別の値として保ちます。

- Entitlement
- Consumption
- Remaining
- unassigned Expense evidence

Household componentはさらに次を観察します。

- eligible AssetとDaily Target
- Envelope signed claimとpositive backing requirement
- policy-selected Asset funding
- backing surplus
- unassigned Budget reconciliation evidence
- open Plan reserve

同じEnvelopeへ複数Commodityが存在しても一つのnumberへ潰しません。overspent claimはsigned valueとして保持し、backing requirementではpositive partだけを使用します。

詳細は[`docs/DAILY_TARGET_POLICY.md`](docs/DAILY_TARGET_POLICY.md)と[`docs/HOUSEHOLD_BACKING.md`](docs/HOUSEHOLD_BACKING.md)にあります。

## Editor boundary

EditorはAccount、Money、Transaction、Journal、Plan、Budget、Issueの意味を再実装しません。

```text
user intent
  -> typed edit intent
  -> pure candidate fragment
  -> candidate complete source
  -> stable admission
  -> preview
  -> explicit publication effect
```

current CLI operation:

- Actual append and multi-posting append
- Actual reverse
- Account declaration append
- Budget movement append
- Household Issue append
- Plan add
- Plan finish

Plan editはcurrent CLI operationではありません。

Actual add TUIはexisting candidate preparationとsafe writerを使うdelivery adapterです。complete private sourceやwriter authorityをUI stateへ持ち込みません。cutover後のordinary canonical Actual addは、このTUIを`tools/hk actual-add <ACTUAL_JOURNAL>`から起動します。

Actual reverseのdaily routeは既存CLIへ`reverse` leafと残りの引数を委譲するだけです。candidate preparation、admission、publication、provenanceは既存のnamed ownerから動かしません。

## Architecture map

```text
src/             stable accounting, Journal, Plan, Budget, Report
household-src/   stable household policy and admissions
editor-src/      editor intent, candidate, safe writer
spike-src/       provisional Household Report composition
app/             report CLI adapter
editor-app/      editor CLI adapter
editor-tui-app/  Actual add TUI adapter
tools/hk         daily routing-only doorway
tests/           focused, property, integration and ownership evidence
```

Dependency directionとeffect ownershipは[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)が所有します。

## Documentation entrypoints

- [`docs/CODE_MAP_AND_DESIGN_SKETCH.md`](docs/CODE_MAP_AND_DESIGN_SKETCH.md): 全体のコードスコアと設計机
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、dependency、effect、domain invariant
- [`docs/HASKELL_NATIVE_CODE_POLICY.md`](docs/HASKELL_NATIVE_CODE_POLICY.md): domainとHaskellの対応
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editor CURRENT、NEXT、cutover後の運用観察
- [`docs/ACTUAL_WRITER_CUTOVER_001.md`](docs/ACTUAL_WRITER_CUTOVER_001.md): `actual.journal` writer authority、activation、rollback
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): private source topologyとsource別writer authority
- [`docs/REPORT_CONFIGURATION.md`](docs/REPORT_CONFIGURATION.md): report source selection
- [`docs/REPORT_VERIFICATION.md`](docs/REPORT_VERIFICATION.md): report verification contract
- [`SECURITY.md`](SECURITY.md): public/private boundary
