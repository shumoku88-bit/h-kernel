# h-カーネル


型で不正な状態を排除する、複数通貨対応の複式簿記エンジンです。
Haskellだけで実装することではなく、**純粋な計算核と副作用の境界を分離すること**を重視しています。


## 現在の特徴


- `Scientific`による正確な10進数量（`Double`不使用）

- 実行時に検証される任意のCommodity（JPY、USD、BTCなど）

- Commodityごとに独立した複式簿記の均衡検証

- 不均衡な`Transaction`を生成できないAPI

- `AccountType`、既定Commodity、`AccountRegistry`による明示的なAccount metadata

- 未宣言Accountと既定Commodity不一致をPostingのsource line付きで拒否する二段階検証

- 未解決includeを検証済みJournalと混同しない`JournalDocument`型

- include元のdirectoryを基準に再帰的な相対includeを解決するIO loader

- include循環を有限な`LoadError`として停止する検出

- 行番号と理由を保持する純粋なJournal parser

- 日付範囲を型で検証する純粋な集計エンジン

- Trial Balance、Balance Sheet、Profit and Loss、Daily Flow、Monthly Accounts、Recent Transactions、Cycle Accountsの純粋なレポートモデル

- Journalとは別の型付きpolicyから作る基本Envelope Budget

- Journal-only Reportを順序付きで束ねる純粋な`ReportBook`

- ANSI装飾前のraw textでCJK列幅を決める純粋なterminal renderer

- 純粋なcommand ownerと薄いIO shell


## ビルドとテスト


```bash
cabal build all
cabal test all
```


GitHub ActionsではGHC 9.10.3、9.12.4、9.14.1で`cabal build all`と`cabal test all`を実行します。


`examples/sample.journal`と`tests/corpus/synthetic-v1/`は、名称・日付・金額を最初から架空にした公開test専用データです。正規世帯sourceは別のprivate repositoryに置き、このGit履歴、fixture、CIには含めません。公開境界は[`SECURITY.md`](SECURITY.md)を参照してください。


## 外部の正規世帯source


引数を省略した`./report`と`./report all`は、`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`が設定されていれば、そのdirectoryの`actual.journal`とHousehold source setを読みます。未設定時は`journal.journal`、続いて公開sample Journalを使用します。


```bash
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
./report all
```


`ledger-data.local`を使う場合は、private data directoryのpathを一行で記述します。このfileは`.gitignore`対象です。


現在のwriterはbqn-ledgerです。bqn-ledgerとh-kernelは同じprivate directoryを参照し、repository間のcopy同期やdual writeは行いません。


```bash
export LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
export REPORT_MANIFEST_CONFIG="$LEDGER_DATA_DIR/report_manifests.tsv"
```


h-kernel editorがvalidation、atomic write、backup、restore、運用rehearsalを満たした時点で、明示的なcutoverによりwriter authorityを移します。詳細は[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)にあります。


private sourceのreview用reportはGit管理外の`.report-artifacts/`へ生成します。


```bash
./report-real-snapshot
```


private source、backup、recovery workspace、生成report、local pathはcommit対象外です。


## Journal形式


Accountの会計上の意味は名前から推測せず、`account` directiveで宣言します。
`wallet:cash`をAssetとして宣言することもでき、反対に`assets:cash`という名前だけではAssetに分類されません。


Accountには任意で既定Commodityを宣言できます。PostingのCommodityは引き続き明示または均衡から推論され、既定値による自動補完はしません。完成したPostingのCommodityがAccountの既定Commodityと異なる場合は、元のPosting行を示すエラーになります。


```text
account wallet:cash
    type: asset
    commodity: JPY

account living:food
    type: expense
    commodity: JPY

2026-08-01 Buy food
    living:food  1000 JPY
    wallet:cash
```


`type:`と`commodity:`の順序に意味はありません。既定Commodityを持たず、複数Commodityを明示的に保持するAccountも宣言できます。


すべてのPostingのAccountには宣言が必要です。Parserはまず全ブロックから`AccountRegistry`とTransactionを作り、その後に各PostingをRegistryへ照合します。そのため、Account宣言を使用箇所より後に置くことはできますが、宣言されていないAccountは元のPosting行を示すエラーになります。


`include` directiveは、IOを行わない純粋Parserによって型付きの参照として保持されます。


```text
include accounts.journal
include transactions/2026.journal
```


`parseJournalDocument`はincludeを含み得る`JournalDocument`を返します。`JournalDocument`はまだ検証済み`Journal`ではありません。


CLIと`loadJournal`は、各includeを**そのincludeを書いたfileのdirectory**を基準に解決します。include先にさらにincludeがある場合も同じ規則で再帰的に読み込みます。循環があれば、たとえば`a.journal -> b.journal -> a.journal`という閉じた経路を持つ`IncludeCycle`として停止します。


純粋な`resolveJournalDocumentIncludes`がinclude blockを子`JournalDocument`へ置換し、IO loaderはfileを読むことと相対pathを決めることだけを担当します。未解決includeを無視した部分的な`Journal`は生成されません。


明示的な数量にはCommodityが必要です。各Transactionにつき1件だけ、数量を省略して均衡額を推論できます。
異なるCommodityは相殺されないため、FX取引はCommodityごとに均衡させます。


## エンベロープポリシー


Envelopeは複式簿記の事実ではなく、Expenseをどう配分して見るかという外部方針です。そのためAccountやTransactionへ埋め込まず、Journalとは別のtab-separated policyとして読み込みます。


```text
# allocation<TAB>ENVELOPE<TAB>QUANTITY<TAB>COMMODITY
allocation	Everyday	40000	JPY
allocation	Travel	100	USD

# assignment<TAB>ACCOUNT<TAB>ENVELOPE
assignment	living:food	Everyday
assignment	living:travel	Travel
```


allocationにはQuantityとCommodityを必ず明示します。同じEnvelopeにJPYとUSDを配賦しても一つの数値へ潰しません。Envelope×Commodityの重複、Accountの重複assignment、allocationのないEnvelopeへのassignment、負のallocationは受理しません。


assignment先はJournalで宣言済みのExpense Accountに限ります。AssetやIncomeをEnvelopeへ割り当てるとReport生成前に失敗します。Consumptionは指定期間内の割当済みExpense Postingから作られ、Remainingは`Entitlement - Consumption`として導出されます。


返金を特定のIncome Account名で特別扱いしません。Expenseの取消しや返金を負のExpense Postingとして記録した場合、その値が自然にConsumptionを減らします。未割当Expenseとmetadataを持たないprogrammatic Accountは黙って消さず、別のevidenceとして表示します。


現在のEnvelope sliceはEntitlement、Consumption、Remainingまでです。planned reserve、funding backing、budget unassigned、reconciliation deltaは後続の独立sliceです。


## 端末のプレゼンテーション


CLIの表示は、型付きの会計計算とは別の互換契約として扱います。


- Report見出しは太字シアンの`== heading ==`

- 期間や基準日はdim表示

- section labelは黄色

- IncomeとAssetは緑、ExpenseとLiabilityは赤

- 正負が意味を持つ結果は符号に応じて緑・赤・dimを選ぶ

- 負数量はマイナス記号ではなく会計括弧（`(1,000 JPY)`）で表示する

- 数量は正確な値を保ったまま3桁区切りで表示する

- 列幅はANSI codeを含まないraw textから計算し、日本語などの全角文字を2桁として扱う


色付きTextを先に作って長さを測るのではなく、各cellがraw textとstyled textを対で持ちます。このためANSI escape sequenceは列幅へ混入しません。計算結果の型やCommodityを表示都合で潰すこともありません。


Daily Flowの計算結果は指定期間全体を保持しますが、端末表示では従来の運用契約に合わせて末尾10日分だけを表示します。これは計算の切り捨てではなくpresentation上の窓です。


## CLIと補助スクリプト


最初に、またはsourceを変更・pullした後に、最適化binaryを準備します。


```bash
sh ./report-build
```


`report-build`は`h-kernel`を`-O2`相当でbuildし、Git管理外の`.report-bin/`へ配置します。日常launcherはCabalを経由せず、このbinaryを直接起動します。


```bash
# 日常用report
./report
./report bs

# 総合household surfaceを合成データで保存
./report-snapshot

# 明示設定したprivate正本をread-onlyで読み、ignored local artifactへ保存
./report-real-snapshot
```


### 性能計測


```bash
sh ./report-benchmark bs
RUNS=10 sh ./report-benchmark daily
```


`report-benchmark`は最適化済みbinaryをwarm-upした後、標準出力を捨てて平均・最小・最大実行時間を表示します。build時間とCabal起動時間は測定に含めません。


### Cabalによる個別実行


```bash
cabal build exe:h-kernel
cabal run exe:h-kernel -- examples/sample.journal check
cabal run exe:h-kernel -- examples/sample.journal all 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal all-reports 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal trial-balance 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal balance-sheet 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal profit-and-loss 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal daily-flow 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal monthly-accounts 2026-01-01 2026-01-31
cabal run exe:h-kernel -- examples/sample.journal cycle-accounts 2025-12-01 2026-01-01 2026-01-01 2026-02-01
cabal run exe:h-kernel -- examples/sample.journal recent-transactions 2026-01-31

# 外部policyを使うEnvelope Budget
cabal run exe:h-kernel -- examples/sample.journal envelope-budget envelope-policy.tsv 2026-01-01 2026-01-31
```


Journal-only commandではJournalファイル名、command、日付を用途に応じて省略できます。Envelope Budgetは別のpolicy pathを必要とするため、`JOURNAL envelope-budget POLICY START END`を明示します。


`Daily Flow`は、指定期間内のIncomeとExpenseだけを日付ごとに集計します。`Monthly Accounts`は同じ計算を暦月へ投影します。どちらもAsset、Liability、Equityの相手Postingを収支へ二重計上せず、Commodityを暗黙に合算しません。


`Recent Transactions`は、明示した基準日以前の検証済みTransactionを新しい順に最大5件表示します。Postingへ平らにせず、descriptionと全Postingを一組のまま保持します。


`all-reports START END`は、Journalだけで完成するReportを次の順番で出力します。


1. 試算表

2. 貸借対照表

3. 損益

4. 一日の流れ

5. 最近の取引

6. 月次アカウント


Envelope Budgetは別のpolicy pathが必要なため、Journalだけを引数にする`ReportBook`へ暗黙には追加しません。


短縮名として`all`、`tb`、`bs`、`pl`、`daily`、`monthly`、`recent`、`envelopes`を使用できます。不正な日付、不明なcommand、読めないファイル、不正なJournalやpolicyは成功扱いになりません。


## モジュール構成


```text
app/Main.hs                                  CLI (h-kernel) エントリポイント
src/HKernel/CLI.hs                           純粋なCommandと引数解釈
src/HKernel/Money.hs                         Commodity、Quantity、Amount、Balance
src/HKernel/Account.hs                       Account identity、AccountType、AccountRegistry
src/HKernel/Ledger.hs                        Posting、検証済みTransaction
src/HKernel/Journal.hs                       Include、JournalDocument、検証済みJournal
src/HKernel/Loader.hs                        Journal file IO、相対include解決、循環検出
src/HKernel/Engine.hs                        期間・Account別の純粋集計
src/HKernel/Report.hs                        Journal-only Reportの公開面とReportBook
src/HKernel/Report/RecentTransactions.hs     opaqueなRecent Transactions owner
src/HKernel/Envelope.hs                      外部policyと純粋Envelope Budget owner
src/HKernel/Envelope/Render.hs               Envelope値とerrorからTextへの純粋描画
src/HKernel/Render.hs                        Journal-only errorとReportの純粋描画
src/HKernel/Render/TerminalStyle.hs          共有terminal presentation primitives
spike-src/HKernel/Spike/HouseholdReport.hs   暫定Household Report library
```


Journal-onlyのデータフローは一方向です。


```text
FilePath
  → IO (Either LoadError Journal)
  → JournalCommand
  → Report / ReportBook
  → Text
  → IO
```


Envelopeは外部方針を明示的に追加します。


```text
PolicyPath → IO Text → Either EnvelopePolicyError EnvelopePolicy
Journal × EnvelopePolicy × DateRange
  → Either EnvelopeBudgetError EnvelopeBudgetReport
  → Text
  → IO
```



現在地と未解決の問いは[`docs/CODE_MAP_AND_DESIGN_SKETCH.md`](docs/CODE_MAP_AND_DESIGN_SKETCH.md)が所有します。債務ポジション固有の未確定設計は[`docs/LIABILITY_POSITION_DESIGN_SKETCH.md`](docs/LIABILITY_POSITION_DESIGN_SKETCH.md)にあります。
