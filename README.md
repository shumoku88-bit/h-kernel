# h-kernel

型で不正な状態を減らし、exact multi-commodity arithmetic、identity、provenance、safe publicationを保つHaskellの家計簿・複式簿記システムです。

目標は、日常の記帳、予定、予算、レポート、Household operationを一つのcanonical source contractの上で安全かつ自然に扱うことです。

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
  -> safe publication effect
```

主なcomponent:

- `h-kernel`: Account、Money、Ledger、Journal、Actual、Plan、Budget、Engine、Report
- `h-kernel-household`: Household policy、Daily Target、Backing、Budget movement、Issue admission
- `h-kernel-editor`: edit intent、candidate preparation、source placement、safe writer
- report CLI、editor CLI、Household TUI、daily entrypoint

## Current capabilities

- `Scientific`によるexact decimal Quantity
- runtimeで検証されるCommodity
- Commodityごとのdouble-entry balance validation
- invalid/unbalanced `Transaction`を後段へ渡さないtyped admission
- explicit `AccountType`と`AccountRegistry`
- include graphを読むtyped Journal loader
- typed `DateRange`とpure Report projections
- Trial Balance、Balance Sheet、Profit and Loss、Daily Flow、Monthly Accounts、Recent Transactions、Cycle Accounts
- Household policy、Daily Target、Backing、Budget、Plan、Issue observation
- Actual append、multi-posting、reverse、Plan lifecycle、Account/Budget/Issue editor operations
- preview、stale rejection、backup、atomic publication、post-admission、restore-capable failure
- keyboard-complete / mouse-friendly Household TUI

## Daily entrypoint

```bash
./tools/hk
./tools/hk --base /path/to/private-ledger-data
./tools/hk report all
./tools/hk actual-add [/absolute/path/to/actual.journal]
./tools/hk actual-multi [/absolute/path/to/actual.journal] ...
./tools/hk actual-reverse [--commit] ...
./tools/hk account ...
./tools/hk plan ...
./tools/hk budget ...
./tools/hk issue ...
./tools/hk edit ...
./tools/hk check
./tools/hk help
```

`tools/hk`はroutingだけを担当し、会計計算、Report rendering、editor admission、source mutationの意味を再実装しません。

## Build and verification

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
```

Reportへ影響する変更では必要に応じて次も実行します。

```bash
./report-build
./report-verify --fixture
./report-verify --corpus
```

## Canonical household source

canonical household sourceはpublic `h-kernel` repositoryではなくuser-owned private repositoryに置きます。

`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`でdirectoryを指定できます。

```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
./tools/hk report all
```

private source、backup、temporary file、recovery workspace、generated report、local pathをpublic Gitへcommitしません。

writer authorityはsourceごとに明示します。現在の契約は[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)と[`docs/ACTUAL_WRITER_CUTOVER_001.md`](docs/ACTUAL_WRITER_CUTOVER_001.md)を参照してください。

## Core invariants

- Accountの意味を名前から推測しない
- QuantityとCommodityを失わない
- 異なるCommodityを暗黙に相殺しない
- durable identityとprovenanceをdisplay textから復元しない
- unresolved / invalid sourceを正常なdomain valueとして扱わない
- UIやCLIへ会計ruleを複製しない
- publicationはexpected source、admitted candidate、stale check、post-admissionを通す

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、dependency、effect、domain invariant
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editor current capabilityとactive roadmap
- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): repository operationとdocument lifecycle
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): private source topologyとwriter authority
- [`docs/REPORT_CONFIGURATION.md`](docs/REPORT_CONFIGURATION.md): report source selection
- [`docs/REPORT_VERIFICATION.md`](docs/REPORT_VERIFICATION.md): report verification contract
- [`SECURITY.md`](SECURITY.md): public/private boundary
