# レポート パイプラインの設計ポリシー


ステータス: 承認済み
承認日: 2026-08-01
範囲: 型付きエンジン（`src/HKernel`、`app/Main.hs`）


## 目的


`h-kernel`では、レポートが増えるほど計算経路が分裂し、同じJournalを各レポートが独自に読み直し・平坦化・分類・集計する構造を作らない。


この方針は、`bqn-ledger`で経験した次の問題を再発させないための設計境界である。


- レポートごとに別々の計算経路が育つ

- 同じ入力を何度も全件走査する

- 期間・分類・符号・未分類Accountの意味がレポート間でずれる

- 表示追加が計算ownerの追加へ直結する

- 全レポート出力がレポート数に比例して遅くなる

- 後から共有kernelへ戻すために広い作り直しが必要になる


この文書は、特定の最適化技法やmodule名を固定するものではない。固定するのは、事実の生成、共有集計、Report投影、描画、IOの方向である。


## 決断


Journal由来のレポートは、次の一方向pipelineを共有する。


```text
Journal files
  -> load / include resolution / parse / validation
  -> validated Journal
  -> canonical accounting facts
  -> shared report basis
  -> typed report projections
  -> Text rendering
  -> IO publication
```


原則は次の一文に要約する。


> 同じ会計上の意味は一つのownerが一度だけ導出し、各レポートは共有された事実を異なる形へ投影する。


## 必要な境界線


### 1. ファイルのロードと検証は 1 回だけ行われます


一回のCLI実行では、master Journalとinclude graphを一つのloader経路で読み、検証済み`Journal`を一度だけ生成する。


Report moduleはfileを読まない。Report rendererはfileを読まない。外部policyを必要とするReportも、Journal loaderを複製しない。


読めないfile、include cycle、parse error、validation errorを空Journalや部分的な成功へ変換しない。


### 2. 正規の会計事実には 1 人の所有者がいる


TransactionからPosting文脈を持つ会計factへ変換する処理は、Reportごとに複製しない。


canonical factは、validated Journalが保持する少なくとも次を失わない。


- 取引日

- トランザクションの順序とトランザクション全体のコンテキスト (必要な場合)

- 説明

- アカウントのアイデンティティ

- 正確な金額と商品


source/provenanceを将来validated Journalが保持する場合は、Report用の平坦化で落とさない。ただし、source identityやprovenance modelの新設は、この共有basis sliceへ混ぜない。


Report固有の表示列やANSI装飾をcanonical factへ入れない。


現在のownerと公開境界は[`REPORT_FACTS_OWNER.md`](REPORT_FACTS_OWNER.md)に記録する。`AccountingFacts`は内部型として育て、公開APIへの昇格は同文書のcheckpointに従って別sliceで判断する。


### 3. 完全なレポートブックでは、レポートごとにジャーナルが再スキャンされません。


複数Reportを一度に生成する経路では、Reportの個数だけPosting全件走査を追加しない。


目標計算量は、Journal Posting数を`P`、Report数を`R`としたとき、`O(R * P)`ではなく、共有basisの準備`O(P)`とReport投影・出力に必要な処理へ近づけることである。


厳密な「一回のfold」を目的化しない。異なる粒度の事実を保つために別走査が必要な場合は許される。ただし、同じ期間選択・Account分類・符号正規化・残高集計をReportごとに再実行することは許容しない。


### 4. 共有セマンティクスが一元化される


次の意味はReportごとに再定義しない。


- as-ofとperiodの境界

- Account metadataによる分類

- Income、Expense、Asset、Liability、Equityの表示符号

- Commodityの保持と合算可能性

- 未宣言・未分類Accountの可視性

- zero balanceを残すか除くか

- future-dated Transactionの扱い

- refund / reversalの会計上の扱い


これらは共有ownerまたは明示的なpolicyによって一度だけ決まり、Reportはその結果を消費する。


### 5. レポート モデルは予測であり、代替エンジンではありません


各Report ownerは、必要な入力と出力型を明示する。


Report moduleが独自のparser、独自のAccount classifier、独自のJournal flattening、独自の残高engineを持たない。


新しいReportを追加するときは、最初に「既存basisのどの座標を投影するか」を説明する。既存basisで表現できない場合だけ、新しい共有座標を追加する。


Report表示の追加を理由に、同じ会計計算の別実装を作らない。


### 6. 個々のコマンドとレポートブックは同じ投影法を使用します


同じ入力条件で単独commandと`all-reports`が生成するReport modelは一致しなければならない。


```text
single command -> prepare shared input -> report projection
all-reports    -> prepare shared input -> same report projection
```


単独command専用の計算式とReportBook専用の計算式を並立させない。


同じresolved requestと同じ`PresentationConfig`に対して、ReportBook内の
section payloadと単独commandの出力payloadも一致しなければならない。
ReportBookは単独用rendererを合成し、別のnumber format、colour policy、
Daily Flow列数を持たない。


```text
CLI + report.toml -> one validated runtime configuration
                       |- report-period policy -> default all only
                       `- presentation policy  -> all and standalone reports
```


設定fileの探索・読込み・validationはCLI shellが一度だけ所有する。
RendererはTOML、環境変数、current working directoryを参照せず、型付き
`PresentationConfig`だけを受け取る。明示CLI期間はReportPlanを上書きするが、
presentation policyを無効化しない。


### 7. トランザクション全体が明確な粒度を維持する可能性がある


`Recent Transactions`のようにTransaction全体を表示するReportは、Posting集計basisへ無理に潰さない。


```text
validated Journal -> whole-transaction view -> Recent Transactions
```


これは経路分裂ではない。TransactionとPosting aggregationは異なる意味粒度だからである。


ただし、単独commandとReportBookは同じTransaction選択・並び順・件数制約を共有する。


### 8. 外部ポリシーのオーバーレイは明示的なままです


Envelope、cycle、plan、targetなどの外部方針は、会計事実へ埋め込まない。


```text
shared accounting facts / report basis
  + validated external policy
  -> policy-specific typed report
```


外部policy ReportはJournal由来の期間残高やflowを独自に再計算せず、共有basisを利用する。policy fileのparse・validationは、そのpolicyのownerが担当する。


### 9. レンダリングはダウンストリームのみで行われます


Rendererはtyped Report modelをTextへ変換するだけであり、Journalを走査しない。Renderer内で会計分類、期間集計、残高調整、fallback計算を行わない。


terminal presentationの契約は、typed Report modelから生成したreview済みsnapshotとgoldenで固定する。presentation契約が会計的正しさを上書きすることはない。


## 意図された共有ベース


最終的な型名やmodule配置は実装sliceで決めるが、共有basisは概念上、次のような座標を持つ。


```text
AccountingFacts
  - canonical posting facts
  - AccountRegistry
  - whole transactions

ReportBasis
  - explicit DateRange and as-of date
  - balances through as-of by Account x Commodity
  - balances in period by Account x Commodity
  - typed flow by day
  - typed flow by calendar month
  - unclassified coordinates
```


保存する値と導出する値を区別する。たとえばNet、Remaining、Deltaのように元座標から一意に求まる値は、矛盾する重複stateとして保存しない。


## 所有権ルール


各semantic sliceには名前のあるownerを置く。


- ローダー: ファイル IO、パス解決を含む

- parser / Journal validation: syntaxとvalid domain value

- 正規の会計事実: `HKernel.Engine.Facts`

- shared report basis: as-of、period、axis別集計

- レポート投影: 型付きレポート モデル

- renderer: Report modelからText

- CLI shell: command selection、必要fileの読込み、publication


汎用helperへ意味を隠さない。複数Reportで共有する計算は、どの会計概念を所有するかが分かる名前を持つ。


## 禁止パターン


次の変更は原則として受け入れない。


- 新Reportのために`journalEntries`相当の平坦化を複製する

- Reportごとに同じDateRange filterを書く

- Account名prefixからReport内で分類を推測する

- 同じIncome / Expense sign normalizationを複数Reportへコピーする

- Rendererが不足値を再計算する

- `ReportBook`が各Reportへ生の`Journal`を渡し、各Reportが全件走査する構造を増やす

- 外部policy Reportが独自のJournal parserや残高engineを持つ

- 性能問題を隠すためだけに、意味ownerが不明なcacheを追加する

- すべてを一つの巨大な万能Report engineへ集約する


最後の項目も重要である。共有basisは意味の共有点であって、全Reportの仕様・policy・renderingを抱える巨大objectではない。


## 現在の実施状況


2026-08-02時点で、`ReportBook`はvalidated `Journal`から内部`AccountingFacts`を一度準備する。Transactionから`LedgerEntry`への平坦化、`AccountRegistry`の参照、whole Transaction grainは一つの値としてPoint、Period、Flow、Recentの各basisへ共有される。


これにより、Reportごとに`journalEntries`を再生成する既知のdebtは解消された。


一方、as-of balance、period balance、flowは、それぞれ異なる座標を導出するために同じcanonical entry listを別々に走査する。これはJournal再平坦化とは異なる残りの計算である。厳密な一回foldへ急いで統合せず、実測と意味grainを確認してから次の有限sliceを交渉する。


## 今後のレポート作業の受付ゲート


Observable outputの共通基準、golden更新規則、実データ確認手順は
[`REPORT_VERIFICATION.md`](REPORT_VERIFICATION.md)に従う。


新しいReportまたは既存Reportの大きな拡張は、PR内で次を示す。


1. 入力factとsemantic grainは何か

2. 既存の共有basisのどの座標を使うか

3. 新しい共有座標が必要なら、そのownerはどこか

4. loader、parser、Journal flatteningを複製していないか

5. 期間、分類、符号、Commodity、未分類の意味を再定義していないか

6. 単独commandとReportBookが同じprojectionを使うか

7. 同じ`PresentationConfig`で両経路のsection payloadが一致するか

8. rendererが計算や設定fileの探索を引き受けていないか

9. focused testでReport間の共通意味を固定しているか

10. full report pathの走査回数またはbenchmark evidenceが悪化していないか

11. correctness変更、architecture変更、presentation変更を一つのsliceへ混ぜていないか


例外が必要な場合は、コード内の便宜的な分岐ではなく、この設計文書または明示的なarchitecture recordを更新して理由を残す。


## 残る建築門


canonical facts preparation後も、point、period、flowの各queryは、それぞれ必要な期間座標について共有entry listを走査する。


次のReport architecture作業を選ぶ前に、少なくとも次を観察する。


- full `ReportBook`で各entryがどのqueryに何回消費されるか

- 異なるas-of日とperiod範囲を一つのquery planへまとめる価値があるか

- ApplicativeまたはMonoidによる独立集計の合成がdomainを明瞭にするか

- 一回fold化が新しい巨大stateや意味owner不明のcacheを生まないか

- 現在のbenchmarkで実用上の問題が観察されるか


その観察後、query-plan fusionを行うか、現在の複数projection走査を明示的に受け入れるかをユーザーと交渉する。


Cycle、Plan、Daily Target、Issues、Envelope backingの追加は、このarchitecture gateの判断後に扱う。


これはP0のloader/parser correctnessや、Report計算経路を変更しない独立した保守作業を停止するものではない。
