# レポートフローの所有者


`HKernel.Report.Flow` は、日次フローと月次アカウントで使用される共有の収入と支出のフロー パスを所有します。


```text
validated Journal
  -> typed Income / Expense contribution
  -> foldMap
  -> Account x Day and Account x Month coordinates
  -> FlowBasis evidence
  -> named report projections
```


所有者には以下の責任があります。


- `DailyFlowPeriod` および `YearMonth` 座標タイプ

- 収入と支出のアカウントメタデータ分類

- 収入記号の正規化

- 日次および月次期間メンバーシップ

- 正確な複数商品の集計

- 日次フローと月次アカウント用の 1 つの共有フォールド


`HKernel.Report` は引き続き以下の責任を負います:


- パブリックの日次フローおよび月次アカウントの結果タイプ

- タイプされた未分類の`AccountLine`証拠の添付

- レポート固有の合計と行の導出

- 共有フロー ベースを他の ReportBook ベースと調整する


`FlowBasis evidence` の `evidence` パラメータは、フロー所有者が特定のパブリック レポート行タイプに依存することを防ぎます。循環モジュール依存関係を導入することなく、レポート所有者によって提供された証拠を保持します。


このスライスでは、ランタイム ディメンション言語の追加、TOML の変更、レポート計算の変更、または端末のプレゼンテーションの変更は行われません。
