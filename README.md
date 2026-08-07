# h-kernel

型で不正な状態を減らし、exact multi-commodity arithmeticを保つHaskellの複式簿記・家計applicationです。

現在の正規データ運用は`h-kernel`へ一本化します。`actual.journal`は現在h-kernelで読み書きでき、残るsourceも順次移行します。`bqn-ledger`は現時点では正規データのreader、writer、fallbackとして使用しません。将来余裕ができたら、同じcanonical Household sourceへのnative対応を進め、reader/writer機能をh-kernelに追いつかせます。この将来対応は現在のh-kernel migration gateではありません。

## 現在の構成

```text
private household source
  -> source-specific admission
  -> exact accounting / policy / projection
  -> Report

user intent
  -> typed candidate
  -> complete-source admission
  -> preview
  -> explicit stale-safe publication
```

- `src/`: Account、Money、Ledger、Journal、Actual、Plan、Budget、Report
- `household-src/`: Household policyとsource admission
- `editor-src/`: edit intent、candidate、safe writer
- `app/`: Report CLI
- `editor-app/`: Editor CLI
- `editor-tui-app/`: Actual workspace TUI
- `tools/hk`: 日常入口とrouting

開発優先順位は[`TODO.md`](TODO.md)、構造は[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)、正データの現在地は[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)を参照してください。

## Setup

正規データはpublic repositoryの外に置き、次のいずれかでdirectoryを指定します。

```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data

# または、Git管理外のledger-data.localへ一行でpathを書く
printf '%s\n' /absolute/path/to/private-ledger-data > ledger-data.local
```

public fixtureとして`examples/sample.journal`と`tests/corpus/synthetic-v1/`を使用できます。private sourceをfixtureへcopyしません。

## Daily commands

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

# daily routerのhelp
./tools/hk help
```

`actual-multi`のjournal pathは現在必須です。path省略と完全なhelp例は[`TODO.md`](TODO.md)のP0で修正します。READMEの例が実装より先に「利用可能」と主張しないようにします。

## Build and verification

```bash
cabal build all
cabal test all
cabal run exe:repository-audit

# 同じ標準検証
./tools/hk check
```

Reportへ影響する変更では次も実行します。

```bash
./report-build
./report-verify --fixture
./report-verify --corpus
```

## Report CLI

```bash
./report
./report bs
./report all
./report-snapshot

cabal run exe:h-kernel -- examples/sample.journal check
cabal run exe:h-kernel -- examples/sample.journal trial-balance 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal balance-sheet 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal profit-and-loss 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal daily-flow 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal monthly-accounts 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal recent-transactions 2026-01-31
```

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

すべてのwriteは次の経路を通します。

```text
typed intent
  -> candidate complete source
  -> strict admission
  -> preview
  -> explicit commit
  -> stale rejection / backup / atomic publication / post-admission
```

正データの内容、path、backup、temporary file、recovery artifactをpublic Git、CI、Issue、logへ出しません。詳細は[`SECURITY.md`](SECURITY.md)を参照してください。

## Documentation

- [`TODO.md`](TODO.md): 作者とcoding assistantが共有する優先順位
- [`AGENTS.md`](AGENTS.md): coding assistantの作業入口
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、依存方向、invariant
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): Editorの現在能力と安全境界
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): 正規sourceとh-kernel移行
- [`docs/HOUSEHOLD_CANONICAL_TARGET.md`](docs/HOUSEHOLD_CANONICAL_TARGET.md): target source shape
- [`docs/REPORT_CONFIGURATION.md`](docs/REPORT_CONFIGURATION.md): Report config
- [`docs/REPORT_VERIFICATION.md`](docs/REPORT_VERIFICATION.md): Report verification
- [`SECURITY.md`](SECURITY.md): private/public boundary
