# h-カーネルのアーキテクチャ


## 境界


`h-kernel`はfunctional core / imperative shellを採用する。


```text
                         pure
Journal Text ──▶ Parser ──▶ Domain ──▶ Engine ──▶ Report ──▶ Renderer
     ▲                                                            │
     └────────────────────── IO shell (Main) ◀─────────────────────┘
```


`Main`だけがファイル、標準入出力、プロセス終了を扱う。Parser、集計、レポート作成、描画はすべて純粋関数である。


## ドメインの不変条件


### 数量と商品


数量は`Scientific`で正確な10進数として保持する。`Amount`は必ず1つの`Commodity`を持つ。異なるCommodityを単一数値へ暗黙変換しない。


### バランス


`Balance`は`Map Commodity Quantity`の不透明な型である。ゼロ要素を持たない正規形をAPIが維持する。


### 取引


`Transaction` constructorは非公開である。`mkTransaction`は以下を検証する。


- 摘要が空でない

- Postingが2件以上ある

- すべてのCommodityが個別にゼロ均衡する


したがって、不均衡なTransactionはEngineへ到達できない。


### ジャーナル


Parserは不正な行を捨てない。失敗は`NonEmpty JournalError`として行番号とともに返す。成功した`Journal`には検証済みTransactionだけが含まれる。


## レポートのセマンティクス


- Trial Balanceは指定日以前を集計する

- Profit and Lossは検証済み`DateRange`内を集計する

- Balance Sheetは未締めのIncomeとExpenseからcurrent earningsを算出する

- 未知のAccount rootは`Other`として保持し、偽のbalanced表示を防ぐ

- すべての合計はCommodity別の`Balance`であり、通貨を混ぜない


## 依存関係の方向


```text
Money
  ▲
Ledger
  ▲
Journal
  ▲
Engine
  ▲
Report
  ▲
Render
  ▲
Main (IO)
```


上位層から下位層への逆向き依存や、Renderからのファイル読み込みは禁止する。
