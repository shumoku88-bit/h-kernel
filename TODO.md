# h-kernel TODO

このファイルは、作者とcoding assistantが同じ優先順位で作業するための単一の入口である。

- coding assistantは作業開始時にこのファイルを最初に読み、最上位の未完了項目から一つの有限sliceを選ぶ。
- 実装の正確な契約は各owner文書とcode/testが所有する。このファイルへ設計詳細や作業日誌を増やさない。
- 完了は、操作例、focused test、必要な正データの非破壊確認で観察できた場合だけチェックする。
- 新しい計画文書を増やさず、必要なら既存文書を置換・統合・削除する。

## 目標

正データを直接編集するより、`h-kernel`から操作する方が速く、分かりやすく、安全な状態にする。

現在の正規運用は`h-kernel`へ一本化する。`bqn-ledger`は現時点のreader、writer、fallbackとして使わないが、廃止はしない。h-kernelが安定した後に同じcanonical Household sourceへnative対応させ、reader/writer機能を追いつかせられる。

TUIはBQN時代のcommand hubを再現しない。UIはdomainのtyped operationとtyped Report requestを選択・入力・表示する薄いadapterとする。

### Application law

日常operationはshell command名ではなくdomainの型として所有する。

```text
HouseholdRoot
  -> source-specific admission
  -> typed Household
  -> typed query / typed intent
  -> pure validation and candidate construction
  -> preview
  -> explicit safe effect
  -> fresh Household reload
```

概念的にはAccount / Actual / Plan / Budget / Issue / Configurationごとに別のoperationとqueryを持つ。巨大なgeneric command ADT、stringly typed argument map、BQN dispatcher互換層は作らない。CLIとTUIは同じdomain operationを異なる入力面から呼ぶだけにする。

## P0: 正データ操作を全部取り戻す

旧bqn-ledgerの日常操作を最低線として、canonical sourceに対する操作をh-kernelで復元する。旧command名は操作棚卸しにだけ使い、dispatcher構造やTSV protocolは移植しない。

### Actual / Account

旧surface: `account add/list`、`journal add/multi-add/list/reverse`。

- [ ] Account一覧を表示し、AccountType / roleで絞り込める。
- [ ] Actual Transaction一覧を表示し、reverse targetをtyped identityで選べる。
- [ ] ordinary expenseをAccount選択から記帳できる。
- [ ] incomeをAccount選択から記帳できる。
- [ ] asset間move / transferを記帳できる。
- [ ] native multi-posting transactionを2件以上、TUIでは3件以上も自然に入力できる。
- [ ] transaction currency / Commodityを明示できる。
- [ ] Actual reverseを一覧から選び、新しいdurable identityと`reverses` relationを持つinverse transactionとして記帳できる。
- [ ] Account declarationを追加できる。AccountTypeとoptional default Commodityを明示し、名前から意味を推測しない。
- [ ] Account identity / AccountType / default Commodityを変更する必要がある場合の安全なtyped operationを確定する。
- [ ] Actual / Account操作は既存`ActualAppend`、`ActualReverse`、`ActualAccountAppend`と共通safe writerを使う。
- [ ] source cleanupが必要なら意味を変えないpreviewable operationとしてのみ提供する。

元Transactionのin-place delete/editを通常correction pathにしない。訂正はexplicit provenanceを持つ新しいfactで表す現在のlawを維持する。

### Plan

旧surface: `plan list/related/add/finish/budget-sync/edit`。

- [ ] Plan一覧。
- [ ] related Plan一覧。
- [ ] Plan add。
- [ ] Plan edit。少なくともdate / Amountの変更をtyped diff preview付きで行う。
- [ ] Plan finish。Actualへのcompletion evidenceを残し、元Plan factを破壊しない。
- [ ] `plan budget-sync`相当の意味がnative Budget / Plan modelで必要なら、idempotent / recoverableなtyped operationとして復元する。
- [ ] finish後にfollow-up Planを作るrecurring workflowをTUI/CLIのorchestrationとして提供する。新しいwrite primitiveにはしない。
- [ ] recurrence / series / cycle relationなどnative Plan metadataを失わない。
- [ ] open / overdue / futureなどの選択はdate文字列のUI推測ではなくtyped Plan stateから行う。

### Budget

旧surface: `budget add`。

- [ ] Budget movement一覧。
- [ ] `budget.journal`へBudget movementを追加できる。
- [ ] source / destination Budget Account、date、description、exact Amountを選択できる。
- [ ] `budget.toml`のgeneral Budget policyをtypedに編集できる。
- [ ] `household.toml`のallocation Account、unassigned、Plan destination等のhousehold-specific Budget coordinatesをtypedに編集できる。
- [ ] Envelope membership、pacing、backing、Expense assignmentをAccount名prefixから推測しない。

### Household / Issue / configuration

旧surface: `issue add/list/close`。

- [ ] Issue一覧。
- [ ] `issues.tsv`へIssue / Decisionを追加できる。
- [ ] Issue close / resolve / dropをtyped operationとして行える。
- [ ] Issueを会計factへ暗黙変換しない。
- [ ] `household.toml`をtypedに編集できる。
- [ ] `report.toml`をtypedに編集できる。
- [ ] `budget.toml` / `household.toml` / `report.toml`はparse -> typed value -> render -> complete re-admissionを通して保存する。
- [ ] unknown keyを黙って保存・削除しない。
- [ ] application-level defaultが必要ならHousehold fact/policyと混ぜず専用ownerへ置く。

### BQN-only operation inventory

旧editorにはcanonical 8-file rootの外に専用Travel source operationもあった。忘れて落とさず、現在も必要な利用者操作かを分類する。

- [ ] `travel friend add`の現在の必要性とtarget ownerを決める。
- [ ] `travel exchange add`の現在の必要性とtarget ownerを決める。

必要ならHaskell-native ownerを決めて復元する。不要なら、旧source shapeを惰性で残さず理由を記録してretireする。

### 共通write law

すべてのwrite operationは同じeffect boundaryを通す。

```text
typed intent
  -> candidate
  -> complete-source admission
  -> preview
  -> explicit confirmation
  -> stale rejection
  -> backup
  -> atomic publication
  -> post-admission
```

- [ ] UIごとにwriterを再実装しない。
- [ ] sourceごとに別のad-hoc safe-write pathを増やさない。
- [ ] unsupported operationをlegacy applicationへfallbackしない。
- [ ] private canonical sourceで最初のwrite testを行わず、明示的なnon-canonical copyでrehearsalする。
- [ ] 実CLIのparse、preview、commit、再admission、結果確認をend-to-end testし、`cabal test all`または`tools/hk check`へ接続する。

## P1: canonical source / configを完成させる

目標root:

```text
accounts.journal
actual.journal
plan.journal
budget.journal
budget.toml
household.toml
report.toml
issues.tsv
```

- [ ] Household rootから`report.toml`を通常採用する。
- [ ] `accounts.tsv -> accounts.journal` migrationを完了し、Account declarationのownerを一本化する。
- [ ] `budget_alloc.tsv -> budget.journal` migrationを完了する。
- [ ] `daily_target_scope.tsv`の意味を`household.toml` / `plan.journal`へ移し切る。
- [ ] `cycle.tsv` / `config.tsv`の残存意味をtyped ownerへ移す。
- [ ] `plan.tsv` compatibility sourceをnative Plan parity後にretireする。
- [ ] legacy report manifest群の全座標をtyped `report.toml`または別の正しいownerへ移し、retireする。
- [ ] legacy sourceを削除する前にsemantic parity、reader cutover、private source admissionを確認する。
- [ ] canonical basenameはHousehold root ownerが一箇所で解決し、TUI/CLIが個別pathを組み立てない。
- [ ] current h-kernel applicationがlegacy `accounts.tsv`、`budget_alloc.tsv`、`daily_target_scope.tsv`、`plan.tsv`、legacy report manifestを必要としないことを確認する。

## P2: TUIを日常のHousehold applicationにする

現在のActual専用Brick screenを、domain operationとReportへ到達するHousehold workspaceへ育てる。

### Top-level

- [ ] 起動時に`HouseholdRoot`を一度loadし、typed Household / policy / Report configをcontextとして持つ。
- [ ] top-level navigationを`Actual / Plan / Budget / Accounts / Issues / Reports / Settings`程度のdomain単位にする。
- [ ] shell command名やsource filenameをnavigation modelにしない。
- [ ] operation実行後はcanonical rootから再admitして画面を更新する。

### Editing

- [ ] P0で完成した全write operationへTUIから到達できる。
- [ ] Account、Plan、Budget、Issueは一覧から対象を選べる。
- [ ] multi-postingはPosting追加・削除・並べ替えとbalance状態を入力中に確認できる。
- [ ] Account selectorをrole/typeで絞れる。
- [ ] reverse target、Plan、IssueをID手入力ではなく一覧から選べる。
- [ ] validation errorをdomain reasonとして入力画面で表示する。
- [ ] preview / confirm / success / stale / recovery failureを共通interactionとして扱う。

完成条件は「screenが存在する」ことではない。作者が正データを直接編集した方が速いと感じる主な理由がなくなること。

### Reports

TUIから`All reports`と各Reportを個別に開けるようにする。旧BQN portfolioは12 reportを持ち、h-kernelにはTrial Balanceもある。どちらも落とさない。

- [ ] All reports
- [ ] Envelope & Backing (`envelopes`)
- [ ] Account Balances (`balances`)
- [ ] Trial Balance
- [ ] Balance Sheet (`balance-sheet`)
- [ ] Profit & Loss (`profit-and-loss`)
- [ ] Recent Transactions / Recent Journal (`recent`)
- [ ] Planned Payments (`planned`)
- [ ] Cycle Accounts (`cycle-accounts`)
- [ ] Cycle Comparison (`cycle-comparison`)
- [ ] Monthly Accounts (`monthly-accounts`)
- [ ] Daily Flow (`daily-flow`)
- [ ] Daily Target (`daily-target`)
- [ ] Issues (`issues`)

現在h-kernelに存在するReport projection / Household surfaceを再利用する。TUIでReport本文を再計算しない。`Cycle Comparison`など現在のh-kernel typed inventoryに欠けるReportは、まずtyped Reportとして復元してからTUIへ載せる。

- [ ] Report catalog画面から一件選択して表示できる。
- [ ] `All reports`で登録順に全Reportを閲覧できる。
- [ ] 前後Reportへ移動できる。
- [ ] Reportごとのdate / range / count / comparison等をtyped controlで変更できる。
- [ ] Reportごとのquery defaultとpresentationは`report.toml`から得る。
- [ ] 必要なReportだけその場でoverrideできるが、source filenameをReport requestへ埋め込まない。
- [ ] unavailable / error / emptyを数値0や空成功画面へ潰さない。
- [ ] Report間で可能な範囲で同じadmitted Household / report basisを共有し、sourceを画面ごとに再parseしない。

## P3: CLIを薄く保つ

CLIはTUIの代替実装ではなく、同じtyped operationを直接呼ぶ入口とする。

- [ ] `--base` / `HKERNEL_LEDGER_DATA_DIR` / `ledger-data.local`からHousehold rootを一度解決する。
- [ ] `actual-multi`を含む各commandでsource path手入力を日常経路から外す。
- [ ] `tools/hk help`へコピーして使える完全な構文を載せる。
- [ ] CLIとTUIでvalidation / preview / writer semanticsを共有する。

## P4: 文書とcompatibilityを削る

- [x] 完了済みreview、BQN観察記録、将来adapter設計、重複code mapをGit履歴へ戻した。
- [x] README / AGENTS / source migration ownerを現在の運用へ圧縮した。
- [ ] native source切替後、retained parser / compatibility builderをparity evidenceの役目が終わった順に削る。
- [ ] current codeを説明しない設計文書を増やさない。
- [ ] `repository-audit`で文書ownerとリンクを継続検証する。

## 将来: bqn-ledger cross-engine parity

h-kernelの正規運用を完成させた後、`bqn-ledger`を同じcanonical Household sourceへ追いつかせる。

- native Journal / TOML sourceを直接admitする
- source syntax、version、identity、ordering、errorを言語非依存のcontractとして共有する
- h-kernelと同じprovenance / exact arithmetic / balance semanticsを保持する
- Actual、Account、Plan、Budget、Issue、configurationの同じoperationを実装する
- 同じReport queryに対する会計factと集計結果を一致させる。terminal layoutの完全一致は別に判断する
- 独立したsynthetic parity corpusを両実装で実行し、private sourceをfixtureにしない
- dual writeせず、一操作につき一つのapplicationだけを使い、次の操作前にfresh sourceを読む

この将来項目のためにh-kernel側へ旧BQN compatibility layerやgeneric argument shapeを持ち込まない。

## 作業順

1. P1のnative root reader migrationを現在の並行PRから着地させる。
2. P0のwrite operationをsourceごとに完成させる。特にPlan edit、native Budget Journal writer、typed config writerを埋める。
3. P2で既存typed operationをTUIへ接続し、Report browserを追加する。
4. P3でCLIのpath / help / interactionを同じapplication layerへ寄せる。
5. P4で役目を終えたcompatibility codeと文書を削る。
6. h-kernelが日常運用で安定してからbqn-ledger catch-upを再開する。

一つのsliceでsource migration、domain correctness、UI redesignを全部変更しない。目的地は一つだが、実装は小さく運ぶ。