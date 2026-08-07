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

## P0: 正データ操作を全部取り戻す

旧bqn-ledgerの日常操作を最低線として、canonical sourceに対する操作をh-kernelで復元する。

### Actual / Account

- [ ] ordinary expenseをAccount選択から記帳できる。
- [ ] incomeをAccount選択から記帳できる。
- [ ] asset間move / transferを記帳できる。
- [ ] native multi-posting transactionを2件以上、TUIでは3件以上も自然に入力できる。
- [ ] transaction currency / Commodityを明示できる。
- [ ] Actual reverseを一覧から選び、新しいdurable identityと`reverses` relationを持つinverse transactionとして記帳できる。
- [ ] Account declarationを追加できる。AccountTypeとoptional default Commodityを明示し、名前から意味を推測しない。
- [ ] Actual / Account操作は既存`ActualAppend`、`ActualReverse`、`ActualAccountAppend`と共通safe writerを使う。

### Plan

- [ ] Plan add。
- [ ] Plan edit。少なくともdate / Amountの変更をtyped diff preview付きで行う。
- [ ] Plan finish。Actualへのcompletion evidenceを残し、元Plan factを破壊しない。
- [ ] recurrence / series / cycle relationなどnative Plan metadataを失わない。
- [ ] open / overdue / futureなどの選択はdate文字列のUI推測ではなくtyped Plan stateから行う。

### Budget

- [ ] `budget.journal`へBudget movementを追加できる。
- [ ] source / destination Budget Account、date、description、exact Amountを選択できる。
- [ ] `budget.toml`のgeneral Budget policyをtypedに編集できる。
- [ ] Envelope membership、pacing、backing、Expense assignmentをAccount名prefixから推測しない。

### Household / Issue / configuration

- [ ] `issues.tsv`へIssue / Decisionを追加できる。
- [ ] Issue statusを更新できるか、append-only lifecycleとして表すかを現在のsemantic ownerに合わせて完成させる。
- [ ] `household.toml`をtypedに編集できる。
- [ ] `report.toml`をtypedに編集できる。
- [ ] application-level defaultが必要ならHousehold fact/policyと混ぜず専用ownerへ置く。

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
- [ ] unsupported operationをlegacy applicationへfallbackしない。
- [ ] private canonical sourceで最初のwrite testを行わず、明示的なnon-canonical copyでrehearsalする。
- [ ] end-to-end testを`cabal test all`または`tools/hk check`へ接続する。

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

- [ ] `accounts.tsv -> accounts.journal` migrationを完了し、Account declarationのownerを一本化する。
- [ ] `budget_alloc.tsv -> budget.journal` migrationを完了する。
- [ ] `daily_target_scope.tsv`の意味を`household.toml` / `plan.journal`へ移し切る。
- [ ] `cycle.tsv` / `config.tsv`の残存意味をtyped ownerへ移す。
- [ ] `plan.tsv` compatibility sourceをnative Plan parity後にretireする。
- [ ] legacy report manifest群の全座標をtyped `report.toml`または別の正しいownerへ移し、retireする。
- [ ] legacy sourceを削除する前にsemantic parity、reader cutover、private source admissionを確認する。
- [ ] canonical basenameはHousehold root ownerが一箇所で解決し、TUI/CLIが個別pathを組み立てない。

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
- [ ] preview / confirm / success / stale / recovery failureを共通interactionとして扱う。

### Reports

TUIから`All reports`と各Reportを個別に開けるようにする。

- [ ] All reports
- [ ] Envelope & Backing
- [ ] Account Balances / Trial Balance
- [ ] Balance Sheet
- [ ] Profit & Loss
- [ ] Recent Transactions
- [ ] Planned
- [ ] Cycle Accounts
- [ ] Cycle Comparison
- [ ] Monthly Accounts
- [ ] Daily Flow
- [ ] Daily Target
- [ ] Issues

現在h-kernelに存在するReport projection / Household surfaceを再利用する。TUIでReport本文を再計算しない。`Cycle Comparison`は旧BQN reportに存在し、現在のh-kernel section inventoryでは欠けているため、まずtyped Reportとして復元してからTUIへ載せる。

- [ ] Report一覧から一件選択して表示できる。
- [ ] 前後Reportへ移動できる。
- [ ] Reportごとのquery defaultは`report.toml`から得る。
- [ ] 必要なReportだけその場でoverrideできるが、source filenameをReport requestへ埋め込まない。

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
