# h-kernel

h-kernelは、日々の記帳、予定、Envelopeによる家計管理、Issue、振り返りを一つのHouseholdとして扱うHaskell製の家計簿です。

普段使うときに必要なのは、家計簿としての操作です。記帳する、予定を実績にする、Envelopeの残りや裏付けを見る、Issueを扱う、時間上の変化を見る。会計や内部実装の知識を日々の操作に要求しないことを目指します。

その内側では、日本の家計簿の実用と複式簿記、用途の異なる記録を分けて残す考え方を、typed admission、exact arithmetic、explicit provenance、safe publicationと組み合わせています。

## できること

- 日々の記帳とmulti-posting Actual
- 元記録を書き換えないreversal
- Planの追加・編集・実績化・次回予定の補充
- Envelope Entitlement / Consumption / Fulfillment / Remaining / Commitment / Headroomの観測
- Account、Entitlement transfer、Issue lifecycleとIssue -> Actual realization
- Trial Balance、Balance Sheet、P&L、Daily / Monthly / Cycle Report
- typed Household observationと時間上のChange
- keyboard / mouse対応のBrick TUI
- exact multi-commodity arithmetic

## 日常の入口

通常はこれだけです。

```bash
./tools/hk
```

private Household rootを明示する場合:

```bash
./tools/hk --base /absolute/path/to/private-ledger-data
```

`tools/hk`は**Brick TUIを起動するだけのlauncher**です。Report、CLI writer、repository check、AI consultationをroutingするCommand Hubではありません。

Household rootは次の順で解決します。

1. `--base DIR`
2. `HKERNEL_LEDGER_DATA_DIR`
3. Git管理外の`ledger-data.local`

## 他のdelivery

低水準のeditor CLIやguided Haskeline dialogueは独立したdeliveryとして残っています。TUIの下にあるdomain/editor ownerを共有しますが、`tools/hk`を経由しません。

例えばHaskeline dialogueを明示的に使う場合:

```bash
cabal run exe:h-kernel-editor-haskeline -- /absolute/path/to/private-ledger-data
```

CLI operationが必要な場合は`h-kernel-editor-cli`のnamed commandへ直接到達します。shell launcherがAccount / Plan / Issueなどのcommand grammarを再所有しません。

## Report

既存のReport entrypointは独立しています。

```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
./report all
```

Reportはcanonical Household admissionとtyped report ownersを使います。`tools/hk`はReportをroutingしません。

## Read-only AI Concierge

家計相談用のread-only observation laneはTUIから独立しています。

```bash
./tools/concierge overview
./tools/concierge export
./tools/concierge packet
```

必要なら:

```bash
./tools/concierge --base /absolute/path/to/private-ledger-data overview
```

consultation protocolとwriter boundaryは[`docs/AI_CONCIERGE.md`](docs/AI_CONCIERGE.md)を参照してください。

## 内部の仕組み

```text
private Household source
  -> named source admission
  -> exact accounting / policy / temporal observation
  -> typed Household / Report surfaces

edit intent
  -> pure candidate
  -> strict complete-source admission
  -> preview when meaningful
  -> safe publication effect
  -> fresh Household admission
```

主なcomponent:

- `h-kernel`: Account、Money、Ledger、Journal、Actual、Plan、Envelope、Engine、Report
- `h-kernel-household`: Household policy、Daily Target、Backing、Envelope observation、Issue admission、Household Report
- `h-kernel-household-application`: canonical Household admissionとtemporal composition
- `h-kernel-editor`: edit intent、interaction helper、candidate preparation、safe writer
- delivery: report app、editor CLI、Brick TUI、guided Haskeline dialogue

BrickはTUI executableだけに依存し、domain / Household / editor libraryはUI toolkitを知りません。将来GUIを追加する場合も、TUI widgetを共有するのではなく同じtyped observation / interaction / publication ownerを別deliveryから利用します。

## Money

`Commodity`はJPYなどの閉じたenumではなくvalidated runtime identityです。`Quantity`は`Scientific`によるexact decimalです。

```text
100 JPY + 2 USD
  -> one Amountにはしない
  -> Balance { JPY = 100, USD = 2 }
```

異なるCommodityを暗黙換算しません。為替valuationが必要になった場合もnative Amountとは別のprice evidence / projectionとして扱います。

## Build and verification

通常のrepository qualification:

```bash
./tools/check
```

Reportへ影響する変更:

```bash
./tools/check-report
```

private canonical Household sourceへ影響する変更:

```bash
./tools/check-household --base /absolute/path/to/private-ledger-data
```

repository exploration:

```bash
./tools/repo-map
./tools/repo-context HKernel.Envelope.Remaining
```

これらはそれぞれ一つの開発責任だけを持つtoolで、日常TUI launcherとは分離されています。

## 正データ

canonical Household sourceはpublic `h-kernel` repositoryではなくuser-owned private repositoryに置きます。

private source、backup、temporary file、recovery workspace、generated report、local pathをpublic Gitへcommitしません。

現在のcanonical source shapeは[`docs/HOUSEHOLD_CANONICAL_SOURCE.md`](docs/HOUSEHOLD_CANONICAL_SOURCE.md)、source別writer authorityは[`docs/WRITER_AUTHORITY.md`](docs/WRITER_AUTHORITY.md)を参照してください。

## 内部で守っていること

- Accountの意味を名前から推測しない
- QuantityとCommodityを失わない
- 異なるCommodityを暗黙に相殺・換算しない
- durable identityとprovenanceをdisplay textから復元しない
- unresolved / invalid sourceを正常なdomain valueとして扱わない
- UIやCLIへ会計ruleを複製しない
- publicationはexpected source、admitted candidate、stale check、post-admissionを通す
- current configurationからhistorical meaningを逆算しない
- available-emptyとunavailableを混同しない

## ドキュメント

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、dependency、effect、domain invariant
- [`docs/ENVELOPE_NATIVE_MODEL.md`](docs/ENVELOPE_NATIVE_MODEL.md): Envelope-native model
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): Editor interaction / safe publication / roadmap
- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): repository operationとdocument lifecycle
- [`docs/HOUSEHOLD_CANONICAL_SOURCE.md`](docs/HOUSEHOLD_CANONICAL_SOURCE.md): canonical Household source
- [`docs/WRITER_AUTHORITY.md`](docs/WRITER_AUTHORITY.md): source別writer authority
- [`docs/AI_CONCIERGE.md`](docs/AI_CONCIERGE.md): read-only consultation boundary
