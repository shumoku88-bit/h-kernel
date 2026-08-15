# h-kernel

h-kernelは、日々の記帳、予定、封筒による家計管理、振り返りを一つの流れで扱うHaskell製の家計簿です。

普段使うときに必要なのは、家計簿としての操作です。記帳する、複数の勘定にまたがる取引を記録する、予定を実績にする、次の予定を補充する、封筒の残りや裏付けを見る、レポートを見る。会計や内部実装の知識を日々の操作に要求しないことを目指します。

その内側では、日本の家計簿の実用と複式簿記、用途の異なる記録を分けて残す考え方を、現代のデジタル技術と組み合わせています。金額を正確に扱い、記録同士の関係や履歴を保ち、正データを安全に更新します。

## できること

- 日々の記帳
- 複数の勘定を使う取引の記帳
- 過去の記帳を直接書き換えない取り消し
- 予定の追加・編集・実績化と次回予定の補充
- 予定を実績にした後の封筒配分記録への反映
- 勘定、封筒の配分移動、家計上の検討事項やメモの編集
- 試算表、貸借対照表、損益計算書、日次・月次・期別のレポート
- キーボードとマウスの両方で使えるTUI

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

- `h-kernel`: Account、Money、Ledger、Journal、Actual、Plan、Envelope、Backing、Engine、Report
- `h-kernel-household`: Household policy、Daily Target、Backing、Envelope observation、Budget movement source admission、Issue admission
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

### Budget domainについて

`Budget`は、Envelopeと並ぶ第二のdomain state modelとしては退役しています。現在の意味は、Envelope identity/current policy、historical Expense routing、Entitlement、Actual consumption/refund、Plan commitment/fulfillment、Backingという狭いownerに分けて保持します。

一方で、会計上の`Budget` AccountType、`budget:*` Account、`budget.journal`、`budget.toml`、`BudgetMovement`のような名前は、canonical sourceやwriter contractの語彙として残る場合があります。これらは`BudgetPolicy`や`BudgetObservation`の存在を意味しません。境界は[`docs/BUDGET_DOMAIN_RETIREMENT.md`](docs/BUDGET_DOMAIN_RETIREMENT.md)を参照してください。

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

現在のcanonical reader topologyは[`docs/HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](docs/HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md)、source別writer authorityは[`docs/WRITER_AUTHORITY.md`](docs/WRITER_AUTHORITY.md)を参照してください。`actual.journal`の具体的なcutover契約は[`docs/ACTUAL_WRITER_CUTOVER_001.md`](docs/ACTUAL_WRITER_CUTOVER_001.md)が所有します。

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
- [`docs/BUDGET_DOMAIN_RETIREMENT.md`](docs/BUDGET_DOMAIN_RETIREMENT.md): retired Budget aggregateと残存source vocabularyの境界
- [`docs/ENVELOPE_NATIVE_MODEL.md`](docs/ENVELOPE_NATIVE_MODEL.md): active Envelope-native model
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editor current capabilityとactive roadmap
- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): repository operationとdocument lifecycle
- [`docs/HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](docs/HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md): current canonical reader topology
- [`docs/WRITER_AUTHORITY.md`](docs/WRITER_AUTHORITY.md): source別writer authorityとcutover gate
- [`docs/REPORT_CONFIGURATION.md`](docs/REPORT_CONFIGURATION.md): report source selection
- [`docs/REPORT_VERIFICATION.md`](docs/REPORT_VERIFICATION.md): report verification contract
- [`SECURITY.md`](SECURITY.md): public/private boundary
