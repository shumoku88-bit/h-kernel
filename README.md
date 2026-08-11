# h-kernel

h-kernelは、日々の記帳、予定、予算、振り返りを一つの流れで扱うHaskell製の家計簿です。

普段使うときに必要なのは、家計簿としての操作です。記帳する、複数の勘定にまたがる取引を記録する、予定を実績にする、次の予定を補充する、予算を見る、レポートを見る。会計や内部実装の知識を日々の操作に要求しないことを目指します。

その内側では、日本の家計簿の実用、パチョーリ以来の複式簿記と帳簿群の考え方、現代のデジタル技術を組み合わせています。金額を正確に扱い、Account、Transaction、Planなどの意味とidentity / provenanceを保ち、正データを安全に更新します。

## できること

- 日々のActual記帳
- 3つ以上のpostingを持つmulti-posting記帳
- Actualのreverse
- Planの追加・編集・完了と次回予定の補充
- Plan完了後のBudget sync
- Account、Budget movement、Issueの編集
- Trial Balance、Balance Sheet、Profit and Loss、Daily Flow、Monthly Accounts、Recent Transactions、Cycle Accounts
- keyboardとmouseの両方で使えるHousehold TUI

## 日常の入口

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

## 内部の仕組み

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

内部では次を保ちます。

- `Scientific`によるexact decimal Quantity
- runtimeで検証されるCommodity
- Commodityごとのdouble-entry balance validation
- invalid / unbalanced `Transaction`を後段へ渡さないtyped admission
- explicit `AccountType`と`AccountRegistry`
- include graphを読むtyped Journal loader
- typed `DateRange`とpure Report projections
- preview、stale rejection、backup、atomic publication、post-admission、restore-capable failure

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

## 正データ

canonical household sourceはpublic `h-kernel` repositoryではなくuser-owned private repositoryに置きます。

`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`でdirectoryを指定できます。

```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
./tools/hk report all
```

private source、backup、temporary file、recovery workspace、generated report、local pathをpublic Gitへcommitしません。

writer authorityはsourceごとに明示します。現在の契約は[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)と[`docs/ACTUAL_WRITER_CUTOVER_001.md`](docs/ACTUAL_WRITER_CUTOVER_001.md)を参照してください。

## 内部で守っていること

- Accountの意味を名前から推測しない
- QuantityとCommodityを失わない
- 異なるCommodityを暗黙に相殺しない
- durable identityとprovenanceをdisplay textから復元しない
- unresolved / invalid sourceを正常なdomain valueとして扱わない
- UIやCLIへ会計ruleを複製しない
- publicationはexpected source、admitted candidate、stale check、post-admissionを通す

## ドキュメント

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、dependency、effect、domain invariant
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editor current capabilityとactive roadmap
- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): repository operationとdocument lifecycle
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): private source topologyとwriter authority
- [`docs/REPORT_CONFIGURATION.md`](docs/REPORT_CONFIGURATION.md): report source selection
- [`docs/REPORT_VERIFICATION.md`](docs/REPORT_VERIFICATION.md): report verification contract
- [`SECURITY.md`](SECURITY.md): public/private boundary
