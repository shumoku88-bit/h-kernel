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
./tools/hk dialogue
./tools/hk --base /path/to/private-ledger-data
./tools/hk --base /path/to/private-ledger-data dialogue
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
./tools/hk check-report
./tools/hk --base /path/to/private-ledger-data check-household
./tools/hk help
```

`tools/hk`はroutingだけを担当し、会計計算、Report rendering、editor admission、source mutationの意味を再実装しません。

## 対話式の記帳と封筒移動

`./tools/hk dialogue`は、Haskelineを使った一問ずつ進む対話式の入力です。Brick TUIのフォームをTabや矢印キーで往復する代わりに、今行いたいHousehold操作を選び、必要な情報だけを順番に答えます。

Household rootは他の`tools/hk`操作と同じ規則で決まります。`--base DIR`、`HKERNEL_LEDGER_DATA_DIR`、Git管理外の`ledger-data.local`の順で解決します。

```bash
./tools/hk dialogue
# または
./tools/hk --base /absolute/path/to/private-ledger-data dialogue
```

起動すると次の入口が表示されます。

```text
What would you like to do?
  1. Record an expense
  2. Record income
  3. Move money for Envelopes
  4. Quit
> 
```

### 支出を記帳する

`1. Record an expense`では、次の順に答えます。

```text
Description
  -> Category
  -> Pay from
  -> Amount
  -> Date
  -> Actual preview
  -> Publish? [y/N]
```

`Category`と`Pay from`は、現在のHouseholdと最近のActualから得た候補を番号で選びます。両Accountに同じ既定Commodityがある場合は、例えばJPYなら`Amount [JPY]:`と表示され、`1200`だけで入力できます。必要なら`1200 JPY`のようにCommodityを明示できます。

### 収入を記帳する

`2. Record income`も同じ一本道で進みます。

```text
Description
  -> Receive into
  -> Income source
  -> Amount
  -> Date
  -> Actual preview
  -> Publish? [y/N]
```

支出・収入とも、previewを表示しただけでは正データを書き換えません。`Publish? [y/N]`へ`y`または`yes`と答えた場合だけ、既存のsafe writerを通してpublicationします。成功後はcanonical Household全体を再admitし、fresh snapshotから次の操作へ進みます。

### 封筒へお金を動かす

`3. Move money for Envelopes`では、家計上の意図から操作を選びます。

```text
Envelope money:
  1. Allocate unassigned money to an Envelope
  2. Move money between Envelopes
  3. Return money from an Envelope to unassigned
> 
```

通常の操作でAccount名を入力する必要はありません。現在の`CurrentEnvelopePolicy`にあるEnvelope identityから、必要なEntitlement endpointをh-kernelが解決します。

#### 未割当からEnvelopeへ配分する

```text
Envelope to fund
  -> Amount
  -> Date
  -> Memo
  -> Envelope movement preview
  -> Publish? [y/N]
```

#### Envelope間で移動する

例えば明日の実運用で封筒Aから封筒Bへ予算を移す場合は、次の流れです。

```text
./tools/hk dialogue
  -> 3. Move money for Envelopes
  -> 2. Move money between Envelopes
  -> Move from Envelope: 封筒Aを選ぶ
  -> Move to Envelope:   封筒Bを選ぶ
  -> Amount:             移動額を入力
  -> Date:               日付を確認
  -> Memo:               必要なら変更
  -> Envelope movement previewを確認
  -> Publish? [y/N]
```

移動元に選んだEnvelopeは移動先候補から除外されます。memoを空Enterにすると`move <移動先EnvelopeId>`が使われます。

#### Envelopeから未割当へ戻す

```text
Envelope to release
  -> Amount
  -> Date
  -> Memo
  -> Envelope movement preview
  -> Publish? [y/N]
```

memoを空Enterにすると、操作に応じた既定memoが使われます。

### 対話中の入力規則

- 選択肢は番号で選ぶ
- サブ選択で`q`、`quit`、`cancel`を入力すると現在の操作を取り消してmain dialogueへ戻る
- 最上位menuで`q`、`quit`、`cancel`を入力するとdialogueを終了する
- `Date [YYYY-MM-DD]:`は空Enterで起動時の当日を使う
- `Memo [default]:`は空Enterで表示中のdefaultを使う
- Amountは正の値だけを受け付ける
- `Publish? [y/N]`は`y`または`yes`だけがpublicationを実行する
- publication後のHousehold再admissionに失敗した場合は、追加writeを続けずdialogueを停止する

このdialogueは新しい会計ruleやwriter authorityを所有しません。Actual candidate、Envelope identity/current policy、Entitlement transfer admission、safe publicationは既存のdomain/editor ownerへ委譲し、Haskelineは質問、選択、preview、confirmationというdeliveryだけを担当します。

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
- `h-kernel-household`: Household policy、Daily Target、Backing、Envelope observation、Household Issue admission、Household Report
- `h-kernel-editor`: edit intent、candidate preparation、source placement、safe writer
- report CLI、editor CLI、Household TUI、guided Haskeline dialogue、daily entrypoint

内部では次を保ちます。

- `Scientific`によるexact decimal Quantity
- runtimeで検証されるCommodity
- Commodityごとのdouble-entry balance validation
- invalid / unbalanced `Transaction`を後段へ渡さないtyped admission
- explicit `AccountType`と`AccountRegistry`
- include graphを読むtyped Journal loader
- typed `DateRange`とpure Report projections
- preview、stale rejection、backup、atomic publication、post-admission、restore-capable failure

### Budget domainの完全退役について

`Budget`は、domain state modelおよび会計上のAccountType / physical source語彙として完全に退役しました。EnvelopeはAccountではなく、独立した`entitlement.journal`と`envelope.toml`がEnvelope EntitlementとBackingを所有します。境界は[`docs/BUDGET_DOMAIN_RETIREMENT.md`](docs/BUDGET_DOMAIN_RETIREMENT.md)を参照してください。

## Build and verification

通常のrepository qualificationは次の一つを入口とします。

```bash
./tools/hk check
```

Reportへ影響する変更では必要に応じて次も実行します。

```bash
./tools/hk check-report
```

private canonical Household sourceへ影響する変更では、内容を出力せず次を追加実行します。

```bash
./tools/hk --base /absolute/path/to/private-ledger-data check-household
```

低レベルの`cabal`、`report-*`、verification scriptは、CIやtool実装自体を調査するときの内部入口です。

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
