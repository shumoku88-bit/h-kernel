# h-kernel

型で不正な状態を減らし、exact multi-commodity arithmeticを保つHaskellの複式簿記・家計applicationです。

現在の正規データ運用は`h-kernel`へ一本化します。`actual.journal`は現在h-kernelで読み書きでき、残るsource / configuration / daily operationも順次h-kernelへ移行します。`bqn-ledger`は現時点のreader、writer、fallbackとしては使用しませんが廃止はせず、h-kernelの運用が安定した後に同じcanonical Household sourceへnative対応させて追いつかせます。

目標はReportだけではありません。canonical Household rootの全source/configを読み書きでき、Actual、Account、Plan、Budget、Issue、configurationのdaily operationと全ReportをCLI/TUIから扱える一つのHousehold applicationにします。

## 現在の構成

```text
private Household root
  -> source-specific admission
  -> typed Household / policy / report config
  -> typed operation / typed report request
  -> CLI or TUI

write intent
  -> typed candidate
  -> complete-source admission
  -> preview
  -> explicit stale-safe publication
  -> fresh Household reload
```

- `src/`: Account、Money、Ledger、Journal、Actual、Plan、Budget、Report
- `household-src/`: Household policyとsource admission
- `editor-src/`: edit intent、candidate、safe writer
- `app/`: Report CLI
- `editor-app/`: Editor CLI
- `editor-tui-app/`: Household TUIへ育てるBrick application
- `tools/hk`: 日常入口とrouting

TUIはBQN時代のcommand hubをHaskellで再現しません。Account / Actual / Plan / Budget / Issue / Configurationのtyped operationとtyped Report requestを使う薄いapplication surfaceにします。

開発優先順位と完成条件は[`TODO.md`](TODO.md)、構造は[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)、正データの現在地は[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)を参照してください。

## Canonical Household root

目標shapeは次です。

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

正規データはpublic repositoryの外に置き、次のいずれかでdirectoryを指定します。

```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data

# または、Git管理外のledger-data.localへ一行でpathを書く
printf '%s\n' /absolute/path/to/private-ledger-data > ledger-data.local
```

public fixtureとして`examples/sample.journal`と`tests/corpus/synthetic-v1/`を使用できます。private sourceをfixtureへcopyしません。

## Daily commands

現在利用できる入口です。source pathを日常操作から外す作業やcommand completenessは[`TODO.md`](TODO.md)で追跡します。

```bash
# Actual workspace TUI
./tools/hk
./tools/hk --base /path/to/private-ledger-data

# Report
./tools/hk report all
./tools/hk report bs

# explicit Actual journalでworkspaceを起動
./tools/hk actual-add /absolute/path/to/actual.journal

# multi-posting preview
./tools/hk actual-multi \
  /absolute/path/to/actual.journal \
  2026-08-06 \
  "multi posting" \
  Assets:Cash -1000 JPY \
  Expenses:Food 600 JPY \
  Expenses:Household 400 JPY

# commitする場合はleaf command直後に--commit
./tools/hk actual-multi --commit \
  /absolute/path/to/actual.journal \
  2026-08-06 \
  "multi posting" \
  Assets:Cash -1000 JPY \
  Expenses:Food 600 JPY \
  Expenses:Household 400 JPY

# Actual reversal。defaultはpreview
./tools/hk actual-reverse \
  /absolute/path/to/actual.journal \
  NEW-EVENT-ID TARGET-EVENT-ID 2026-08-06 \
  "correction description"

# その他のEditor command
./tools/hk account /absolute/path/to/actual.journal Assets:Saving asset JPY
./tools/hk plan add ...
./tools/hk plan finish ...
./tools/hk budget ...
./tools/hk issue ...

./tools/hk help
```

## Build and verification

```bash
cabal build all
cabal test all
cabal run exe:repository-audit

./tools/hk check
```

Reportへ影響する変更では次も実行します。

```bash
./report-build
./report-verify --fixture
./report-verify --corpus
```

## Report portfolio

TUI/CLIから最終的に`All reports`と各Reportを個別に扱います。現在のh-kernel projectionと旧daily portfolioで保持していたReport questionをtyped ownerへ統合します。

- Envelope & Backing
- Account Balances
- Trial Balance
- Balance Sheet
- Profit & Loss
- Recent Transactions / Recent Journal
- Planned Payments
- Cycle Accounts
- Cycle Comparison
- Monthly Accounts
- Daily Flow
- Daily Target
- Issues

Report TUIは計算を再実装せず、typed `ReportRequest`から既存/新規のtyped resultを作り、rendererへ渡します。query defaultとpresentationは`report.toml`が所有します。

## Journal format

Accountの意味は名前から推測せず、`account` directiveで宣言します。

```journal
account assets:cash
    type: asset
    commodity: JPY

account expenses:food
    type: expense
    commodity: JPY

2026-08-01 Buy food
    expenses:food  1000 JPY
    assets:cash
```

- Quantityはexact decimal
- Postingが使うAccountは宣言済みであること
- explicit QuantityにはCommodityが必要
- 一Transactionにつき一PostingだけQuantityを省略できる
- Postingは二件以上必要
- Commodityごとにbalanceすること
- 異なるCommodityを暗黙変換しない

`include`は記述fileのdirectoryから再帰解決します。unresolved includeやcycleを無視したpartial Journalは作りません。

## Editor safety

すべてのwriteは次の経路を共有します。

```text
typed intent
  -> candidate complete source
  -> strict admission
  -> preview
  -> explicit commit
  -> stale rejection / backup / atomic publication / post-admission
```

CLI/TUIごとに別writerを作りません。正データの内容、path、backup、temporary file、recovery artifactをpublic Git、CI、Issue、logへ出しません。詳細は[`SECURITY.md`](SECURITY.md)を参照してください。

## Documentation

- [`TODO.md`](TODO.md): 完成条件と作業順
- [`AGENTS.md`](AGENTS.md): coding assistantの作業入口
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、依存方向、invariant
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): Editorの現在能力と安全境界
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): 正規sourceとh-kernel移行
- [`docs/HOUSEHOLD_CANONICAL_TARGET.md`](docs/HOUSEHOLD_CANONICAL_TARGET.md): target source shape
- [`docs/REPORT_CONFIGURATION.md`](docs/REPORT_CONFIGURATION.md): Report config
- [`docs/REPORT_VERIFICATION.md`](docs/REPORT_VERIFICATION.md): Report verification
- [`SECURITY.md`](SECURITY.md): private/public boundary
