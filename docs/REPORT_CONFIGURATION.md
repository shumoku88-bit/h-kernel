# レポート構成


ステータス: 実装契約
範囲: 現在 `ReportBook` が公開している6つのJournal-only Report


## 目的


`all` コマンドを組み合わせても、すべてのレポートが 1 つの日付または 1 つの範囲を継承するように強制されるわけではありません。各レポートはその粒度に適した日付セマンティクスを宣言し、構成はレポート エンジンに到達する前に型指定された値に解決されます。


```text
report.toml
  -> TOML syntax decoding
  -> symbolic ReportPlan
  + one process-local calendar day
  + validated Journal
  -> ResolvedReportPlan
  -> shared report basis
  -> typed report projections

report.toml presentation values
  -> validated PresentationConfig
  -> every Journal report entrypoint
  -> pure terminal renderer
```


TOML 値と構成パスはアカウンティング計算には含まれません。レンダラーは、検証されたプレゼンテーション座標のみを受け取ります。


## 発見


デフォルトの `all` コマンドの場合、h-kernel は次の順序で設定を検索します。


1. `HKERNEL_REPORT_CONFIG` によって名付けられたパス;

2. 現在の作業ディレクトリ内の `report.toml`;

3. 設定ファイルはなく、既存のデフォルトのレポート期間が維持されます。


明示的に構成されたパスは読み取り可能である必要があります。ファイルが見つからない場合や無効な場合でも、サイレントにフォールバックしません。


すべての Journal レポート作成コマンドは、検出されたファイルを 1 回読み取ります。単一レポート コマンド (`pl`、`bs` など) に明示的な CLI 日付または範囲が指定されていない場合、`report.toml` から設定されたレポート期間が自動的に適用されます。明示的な CLI `START END` または日付座標は引き続き権限を持ち、構成されたプレゼンテーション設定を使用しながら、構成された期間をオーバーライドします。 `check` および別個の Envelope コマンドは、このレポート設定を読み取りません。


検出されたファイルは、1 つのアプリケーション構成として検証されます。無効な構文、不明なキー、無効な日付リテラル、または無効なプレゼンテーション値があると、部分的に受け入れられた構成で出力が生成されるのではなく、`all` とスタンドアロンのジャーナル レポート コマンドの両方が失敗します。


## ReportBook とスタンドアロンの同等性


同じ解決されたレポート リクエストと同じ `PresentationConfig` の場合、`all` 内でレンダリングされるペイロードはスタンドアロン レポート ペイロードと等しくなければなりません。レポートブックの構成では、セクション間に区切り文字が追加される場合があります。 2 番目のレンダラー、数値形式、カラー ポリシー、または日付列ポリシーを選択してはなりません。


```text
all        -> resolved report -> shared renderer + PresentationConfig
standalone -> resolved report -> shared renderer + PresentationConfig
```


レポート期間ポリシーとプレゼンテーションポリシーは独立しています。明示的な CLI 日付は、設定された期間座標のみを上書きします。設定されたプレゼンテーションは無効になりません。


## 例


```toml
[presentation.hierarchy]
heading-color = "cyan"
section-color = "yellow"

[presentation.amounts]
negative-style = "parentheses"
positive-color = "green"
negative-color = "red"

[reports.trial-balance]
as-of = "latest"

[reports.balance-sheet]
as-of = "latest"

[reports.profit-and-loss]
from = "2026-06-15"
through = "latest"

[reports.daily-flow]
from = "2026-07-01"
through = "latest"
max-date-columns = 10

[reports.monthly-accounts]
from = "beginning"
through = "latest"

[reports.recent-transactions]
through = "latest"
count = 5
```


`report.toml.example` には同じ完全な形状が含まれています。


## プレゼンテーションのセマンティクス


`presentation.hierarchy` と `presentation.amounts` は独立してオプションです。どちらか一方だけを設定でき、テーブル自体がない場合はその意味の既定値が使われます。


`presentation.hierarchy.heading-color` と `presentation.hierarchy.section-color` は、レポート階層の表示色を選びます。heading はレポート見出し、section は Income / Expenses や Household report 内の小見出しなどを意味します。既定値はそれぞれ `"cyan"` と `"yellow"` です。


`presentation.amounts.negative-style` は以下を正確に受け入れます:


- `"parentheses"` `(1,000 JPY)` 用;

- `"minus"` `-1,000 JPY`用。


デフォルトは`"parentheses"`です。この値は端末表現のみを変更します。符号付きの `Quantity`、`Amount`、および `Balance` の値は変更されません。


`presentation.amounts.positive-color` と `presentation.amounts.negative-color` は、金額表示の positive/green-tone と negative/red-tone を選びます。既定値はそれぞれ `"green"` と `"red"` です。negative tone は負値だけでなく、Expense・Liability など金額として同じ presentation role で描画される行と合計にも使われます。


4つの color 座標は、以下を正確に受け入れます:


- `"red"`, `"bright-red"`, `"green"`, `"yellow"`, `"blue"`, `"magenta"`, `"cyan"`, `"white"`


これらは report hierarchy と amount tone の ANSI 端末カラーだけを変更します。`Balanced: YES/NO` や `backed/under_backed` などの success/failure status は amount palette とは別の意味で、既存の固定 green/red を保ちます。


bold と dim も色ではなく emphasis として固定です。現在の muted/metadata/zero 表示は端末既定foregroundに dim を適用するため、`muted = "bright-black"` のような色座標はこの schema にはありません。


`reports.daily-flow.max-date-columns`もプレゼンテーションコーディネートです。現在の TOML の場所がデイリー フロー テーブル内に残っている場合でも、設定された `all` とスタンドアロンのデイリー フロー出力によって共有されます。


## 日付セマンティクス


### `latest`


`latest` は、プログラムの開始時に一度取得されるプロセスのローカル暦日を意味します。これは、ジャーナル内の最大の取引日を意味するものではありません。 1 つのコマンド内のすべてのレポートで、同じ解決された日が表示されます。


### `beginning`


`beginning` は範囲開始の場合のみ有効です。これは、その範囲の解決された終了日またはそれ以前の最も早いトランザクション日付に解決されます。対象となるトランザクションが存在しない場合は、終了日まで解決され、無効なセンチネル日付ではなく、有効な空の日の範囲が生成されます。


### 明示的な日付


明示的な日付には `YYYY-MM-DD` を使用します。範囲は包括的です。終了後の開始は、影響を受けるレポートの名前を指定する構成エラーです。


## デイリーフローカレンダーブロック


設定または明示的な日次フロー範囲には、収入または支出アクティビティがない日も含め、その包括的な範囲内のすべての暦日が表示されます。


`max-date-columns` は、1 つのテーブル ブロックに表示される日付列の数を制御します。デフォルトは`14`です。 `max-date-columns = 10` を使用した 31 日の範囲は、10 日、10 日、10 日、1 日という垂直方向に積み重ねられた 4 つのテーブルとしてレンダリングされます。


すべてのブロックは同じ行順序を維持します。構成された範囲全体で合計がゼロである収入または支出の行は、すべてのブロックから除外されます。 1 つのブロック内でのみゼロである行は、その完全な期間の合計がゼロ以外の場合、表示されたままになります。


範囲が複数のブロックにまたがる場合、各行は `Block total` で終わり、その後に `Period total` が続きます。 `Block total` は、その表に表示される日付のみをカバーしています。 `Period total` は TOML 範囲全体をカバーし、すべてのブロックで繰り返されます。単一ブロック範囲では、重複する `Block total` 列が省略されます。


構成なしのデフォルトでは、明示的な開始日がない古い無制限の `through` 座標が使用されます。このフォームは、境界のある最近のフロー日ウィンドウを保持し、その右端の列に `Window total` というラベルを付けます。構成された範囲と明示的な `START END` リクエストでは、暦日ブロックが使用されます。


端末幅の検出は意図的にこの契約の外にあります。将来の CLI アダプターは、端末の幅から `max-date-columns` 値を導出し、同じ検証済みの座標を純粋なレンダラーに渡す可能性があります。


## レポート固有のタイプ


|レポート |期間タイプ |

|---|---|

|試算表 |当日現在 |

|貸借対照表 |当日現在 |

|損益 |包含範囲 |

|一日の流れ | TOML の包含範囲。設定なしのデフォルトは、その日の時点まで履歴として残ります。

|月次アカウント |包含範囲 |

|最近の取引 |日中プラス厳密に正のカウント |


この区別により、貸借対照表に意味のない開始日が設定されることがなくなり、最近の取引が期間合計と間違われることがなくなります。


## 共有ベース


構成された期間が異なると、各レンダラーまたはプロジェクションが個別にジャーナルを再読み取りすることは許可されません。


- 試算表と貸借対照表の日付が同じであれば、1 ポイント基準を共有します。

- 等しい損益および月次範囲は 1 期間ベースで共有されます。

- 日次フローと月次アカウントは、範囲が異なる場合でも 1 つのフロー フォールドの座標のままです。

- 日次フローの可視性を一致させると、すでに準備されたポイントまたは期間の分類が再利用されます。

- 最近のトランザクションでは、トランザクション全体が保持されます。


## Legacy Report manifestとの関係

private canonical sourceの`report_all_human.tsv`、`report_all_compact.tsv`、`report_manifests.tsv`は、bqn-ledger daily workflowのlegacy execution configurationである。現在の`report.toml` schemaへそのままcopyするsourceではない。

| legacy coordinate | owner |
|---|---|
| Report key | typed Report kind / future named preset |
| human / compact surface | presentation preset |
| date、month、count | Report query default |
| Commodity | Report query coordinate |
| comparison mode | typed comparison strategy |
| source filename | Application source selection |
| Account list | Household semantic scopeまたはReport-only filter |
| manifest filename | legacy set selectionまたは不要なindirection |

source filename、Household Account classification、Envelope membershipを`report.toml`へ埋め込まない。これらはApplication configまたはHousehold policyが所有する。

将来`report.toml`は、typed entrypointがstableになったReportについてnamed presetとordered setを所有できる。

```text
named report preset
  = report kind
  + typed query defaults
  + presentation selection
  + optional reference to an already-validated Household scope

named report set
  = ordered preset references
```

exact TOML syntaxはまだ固定しない。Reportごとにtyped request、typed query coordinate、Household scope owner、source selectionの分離、legacy invocationとのsemantic parity、shared rendererを確認する。gate前にlegacy rowをgeneric argument arrayとしてTOML化しない。

## Canonical dataとの境界

`report.toml`はReport application configであり、Actual、Plan、Budget、Issue、Account declaration、Household policyの正本ではない。

```text
canonical household facts/policy
  -> typed Report request
  + report.toml defaults/presentation
  + explicit CLI override
  -> rendered Report
```

repository標準profileの配置はdeployment decisionである。legacy manifestがprivate canonical directoryにあることを理由に、`report.toml`をcanonical household factへ格上げしない。legacy Report TSVは、対応するtyped entrypoint、Report preset、parity evidenceが揃った後にretireする。

## エラー


構成では次のものが拒否されます。


- 必要なレポート テーブルまたはキーが欠落している。

- 不明な TOML キー。

- 無効な日付文字列。

- `beginning` 意味がありません。

- 解決された終了後の範囲の開始。

- 最近のカウントがゼロ、負、または表現できないほど大きい。

- ゼロ、負、または表現できないほど大きな `max-date-columns` 値。


構成エラーは失敗として報告されます。これらは、デフォルトのプラン、デフォルトのプレゼンテーション、または空のレポートには変換されません。


## このスライスのノンゴール


この構成によって、会計計算式、勘定科目分類、商品の動作、月次勘定科目の形式、またはその他のレポート テーブルが変更されることはありません。エンベロープ、サイクル、計画、日次目標、または問題レポートは追加されません。動的な端末の幅の検出とサイズ変更の追跡は、将来のプレゼンテーション アダプターとして残ります。
