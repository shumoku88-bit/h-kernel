# レポート パイプラインの設計ポリシー

ステータス: アクティブな正規policy

## 1. この文書の役割

この文書は、Journal由来の会計事実、共有Report basis、typed projection、rendering、IOの依存方向を所有する。

同じ会計上の意味をReportごとに再計算しない。新しいReportは既存ownerの事実を投影し、表示都合で別の会計engineを作らない。

## 2. 正規pipeline

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

依存方向を逆転させない。Report modelはfileを読まず、rendererは会計計算やsource admissionを行わず、delivery adapterは会計ruleを複製しない。

load、parse、validationの失敗を空Journal、欠落fact、partial Reportへ変換しない。

## 3. 所有者

- loader: filesystem IOとinclude path解決
- Journal parser / validation: syntaxとvalid domain value
- `HKernel.Engine.Facts`: canonical accounting factsの内部owner
- `HKernel.Report.Flow`: Daily Flow / Monthly Accountsが共有するflow basisの内部owner
- `HKernel.Report`: public typed report projection
- Report renderer: typed report modelからTextへのpresentation
- CLI / application adapter: command selection、runtime configuration、必要sourceのload、publication

`HKernel.Engine.Facts` はCabalのinternal moduleであり、`HKernel.Engine` がpublic query facadeである。内部型を利用できるようにすること自体を理由にpublic APIへ昇格させない。

## 4. Canonical accounting facts

一つのvalidated `Journal`から`AccountingFacts`を一度準備する。

`AccountingFacts`は異なるsemantic grainを潰さず、少なくとも次を保持する。

- posting grainの`LedgerEntry`
- declared Account meaningのownerである`AccountRegistry`
- whole-transaction reportのための`Transaction`

Posting集計を必要とするReportのためにTransaction全体を捨てず、Transaction全体を必要とするReportをposting aggregateへ無理に変換しない。

Report固有の表示列、ANSI style、TOML設定をcanonical factsへ入れない。

## 5. 共有される意味

次の意味をReportごとに再定義しない。

- as-of / periodの境界
- Account metadataによる分類
- Income / Expense / Asset / Liability / Equityの符号
- exact QuantityとCommodityの保持
- 未宣言、未分類Accountの可視性
- zero balanceの扱い
- future-dated Transactionの扱い
- refund / reversalの会計上の扱い

同じ意味を複数Reportが必要とする場合は、名前のある共有ownerへ置く。意味ownerが不明なgeneric helperやcacheへ隠さない。

## 6. Report projection

Reportはshared facts / basisから作るpure projectionであり、代替engineではない。

```text
single command -> shared input -> report projection
all-reports    -> shared input -> same report projection
```

同じresolved requestに対して、standalone commandとReportBookで別の計算式を持たない。同じ`PresentationConfig`なら同じsection payloadを同じrendererから得る。

Envelope、cycle、plan、targetなど外部policyを必要とするReportは、validated policyを明示的に重ねる。

```text
shared accounting facts / report basis
  + validated external policy
  -> policy-specific typed report
```

外部policyのためにJournal loader、Account classifier、残高engineを複製しない。

## 7. RenderingとIO

Rendererはtyped report modelをTextへ変換するだけである。

Rendererは次を行わない。

- Journalやpolicy fileを読む
- Accountを再分類する
- 期間集計や残高調整を行う
- fallback値を計算する
- environmentやcurrent working directoryから設定を探索する

runtime configurationの探索、読込み、validationはapplication / CLI boundaryが所有し、rendererには型付き設定を渡す。

## 8. 禁止する構造

- ReportごとのJournal flattening
- Reportごとの同一DateRange filterやsign normalization
- Account名prefixからの会計分類推測
- `ReportBook`から各Reportへ生Journalを渡し、同じ意味を各Reportが再導出する構造
- presentation追加を理由にした別会計経路
- 性能問題を隠すだけの意味owner不明なcache
- 全Reportのpolicy、projection、renderingを抱える万能Report object

共有basisは意味の共有点であり、巨大な第二engineではない。

## 9. 変更時のgate

新しいReportまたは既存Reportの大きな変更では、少なくとも次を確認する。

1. 入力factとsemantic grainのownerが明確か
2. loader、parser、Journal flattening、会計分類を複製していないか
3. 既存のshared facts / basisを再利用できるか
4. standalone commandとReportBookが同じprojectionを使うか
5. rendererへ計算や設定file IOを移していないか
6. exact arithmetic、Commodity、unknown evidenceを失っていないか
7. focused testで共有semanticsを固定しているか
8. observable output変更は[`REPORT_VERIFICATION.md`](REPORT_VERIFICATION.md)の契約で検証したか

性能変更を理由にarchitectureを変える場合は、現在の実測を根拠にする。一回foldやcacheの導入自体を目的にしない。
