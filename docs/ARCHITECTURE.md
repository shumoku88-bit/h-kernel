# h-kernel アーキテクチャ

ステータス: アクティブな正規architecture  
更新日: 2026-08-07

## 1. この文書の役割

この文書は、`h-kernel`の安定したcomponent境界、依存方向、会計上の不変条件、effectの置き場所を所有する。

優先順位は[`../TODO.md`](../TODO.md)、Haskellの書法は[`HASKELL_NATIVE_CODE_POLICY.md`](HASKELL_NATIVE_CODE_POLICY.md)、正規sourceとwriterの現在地は[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)が所有する。

## 2. Functional coreと明示的なeffect boundary

`h-kernel`は、一つの巨大な`Main`ではなく、複数のpure componentと狭いdelivery adapterから構成する。

```text
external source / user intent
          |
          v
report app / editor CLI / editor TUI / tools/hk
          |
          v
explicit loader or writer effect
          |
          v
validated typed values
          |
          v
pure accounting / policy / projection / candidate / interaction
          |
          v
rendered result or validated candidate
          |
          v
stdout / exit status / atomic publication
```

pure coreは、file path、process exit、interactive event loop、atomic renameを会計計算へ持ち込まない。effect boundaryは、effectを隠すためではなく、どの外界へ触れているかを型とcomponentから読めるようにするために置く。

## 3. Current components

```text
h-kernel
  source: src/
  owns:
    Account, Money, Ledger, Journal, Actual, Plan, Budget,
    Engine, Report, rendering primitives, application config admission

h-kernel-household
  source: household-src/
  depends on: h-kernel
  owns:
    AccountProfile admission, HouseholdPolicy, DailyTarget,
    HouseholdBacking, BudgetMovement, Household Issue admission

h-kernel-editor
  source: editor-src/
  depends on: h-kernel + h-kernel-household
  owns:
    typed edit intent, pure candidate preparation, source placement,
    complete-source admission, stale check, backup, atomic publication,
    post-admission and restore-capable writer result,
    typed Actual workspace projection, UI-independent Actual add interaction

h-kernel-spike-household-report
  source: spike-src/
  depends on: h-kernel + h-kernel-household
  owns:
    provisional Household Report composition and rendering
```

Delivery adaptersはlibraryとは別に置く。

```text
app/             h-kernel report executable
editor-app/      h-kernel-editor-cli
editor-tui-app/  Brick Actual workspace executable
repository root  report launchers and build helpers
tools/hk         workspace-first daily doorway + explicit command routing
tools/           repository audit and verification tools
```

`tools/hk`はdomain ownerではない。TTY no-argではActual workspaceへ入り、explicit commandではreport / actual-add / actual-multi / actual-reverse / account / plan / budget / issue / edit / check / helpを既存entrypointへrouteする。会計計算、Report rendering、editor admission、source mutation、audit ruleを再実装しない。

## 4. Effectの所有者

### 4.1 Journal load

`HKernel.Journal`のparserとinclude解決はpureである。`HKernel.Loader`はfilesystem上のinclude graphを読むadapterであり、必要なeffectを次の重なりとして明示する。

```haskell
StateT LoadedFiles (ExceptT LoadError IO)
```

- `LoadedFiles`: include循環と既読状態
- `LoadError`: typed failure
- `IO`: file readとpath resolution

loaderが読んだ後のAccount validation、Transaction validation、集計、Report projectionはpure ownerへ戻す。

### 4.2 Editor publication

editorの候補生成とcomplete-source admissionはpureである。filesystem mutationは`h-kernel-editor`のsafe writer boundaryが所有する。

```text
expected old bytes
  + validated candidate bytes
  -> stale rejection
  -> backup
  -> sibling temporary file
  -> atomic publication
  -> post-admission
  -> success or restore-capable failure
```

CLIやTUIはこの順序を複製しない。UI-independent interaction stateへcomplete private source、backup、writer authorityを持ち込まない。

Delivery adapterがpreviewとsafe writerのexpected-old-bytes境界を接続するため読み込んだsource bytesを保持する場合、その値はdomain / interaction stateではなくeffect-delivery contextとして明示する。このplacement自体を変更するときはwriter correctnessとstale contractを別sliceで検証する。

### 4.3 Application and terminal

report app、editor app、Brick TUI、shell launcherは、引数、環境変数、標準入出力、終了状態、terminal eventを扱う。会計ruleやsource admissionをadapter都合で再実装しない。

Brick固有のpane、focus、cursor、key mapping、widget、renderingは`editor-tui-app/`に置く。Account selection identity、workspace projection、Actual add interaction transitionは共有typed ownerへ委譲する。

## 5. Domain invariants

### 5.1 QuantityとCommodity

Quantityは`Scientific`による正確な10進数として保持する。`Amount`は必ず一つの`Commodity`を持つ。異なるCommodityを一つの数値へ暗黙変換しない。

### 5.2 Balance

`Balance`はCommodityごとのQuantityを保持するopaqueなcanonical valueであり、zero entryを持たない。

`Semigroup` / `Monoid`は、同じ観察文脈にあるBalance contributionの結合を所有する。Transaction、Journal、Plan lifecycleなど、順序、identity、provenanceを持つ値へ同じinstanceを機械的に広げない。

### 5.3 Account

Accountの意味は名前から推測しない。`AccountRegistry`と検証済みdeclarationがAccount identity、`AccountType`、optional default Commodityを所有する。

UIでadmitted Accountを選択する場合も、表示Textをidentityとして使わず`Account`を保持し、presentation boundaryでだけ`accountName`へ落とす。

### 5.4 Transaction

`Transaction` constructorは公開しない。smart constructorとJournal admissionは少なくとも次を保証する。

- descriptionが空でない
- Postingが二件以上ある
- Accountが宣言済みである
- QuantityとCommodityが正確である
- Commodityごとにzero balanceである

不均衡または未解決のTransactionをEngineやReportへ渡さない。

### 5.5 Actual identityとreversal

Actualのdurable identityとreversal relationは`HKernel.Actual.Journal`がadmitする。reversalは元Transactionを変更せず、新しいdurable `event-id`とexplicit `reverses` relationを持つinverse Transactionとして追加する。

詳細は[`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md)が所有する。

## 6. Report and Household projections

Reportはvalidated factsから作るpure projectionである。

- Trial Balanceは指定日以前のAccount balanceを観察する
- Profit and Lossはvalidated `DateRange`内のIncomeとExpenseを観察する
- Balance Sheetは未締めIncome / Expenseからcurrent earningsを導出する
- Daily Flow、Monthly Accounts、Recent Transactions、Cycle Accountsはそれぞれ名前付きownerを持つ
- 合計はCommodity別の`Balance`を保つ
- unknown classificationやunassigned evidenceを黙って消さない

Household policy、Daily Target、Backing、Budget movement、Account profile admissionはstable `h-kernel-household` componentにある。現在のHousehold Report compositionだけがspike componentに残る。

## 7. Dependency direction

```text
h-kernel-household              -> h-kernel
h-kernel-editor                 -> h-kernel
h-kernel-editor                 -> h-kernel-household
h-kernel-spike-household-report -> h-kernel
h-kernel-spike-household-report -> h-kernel-household

report app                      -> h-kernel + h-kernel-spike-household-report
editor app / editor TUI         -> h-kernel-editor
tools/hk                        -> existing report launcher / editor CLI / editor TUI / checks
```

次は禁止する。

- `h-kernel`から`h-kernel-editor`への依存
- `h-kernel-household`からeditorへの依存
- Report ownerからfilesystem writerへの依存
- Render ownerからsource readへの依存
- daily routerまたはdelivery adapterへの会計rule / mutation ruleの移動
- UI toolkit型のshared interaction ownerへの流入
- spike-local parserによるstable admissionの再実装

## 8. 正規application

`h-kernel`が現在の正規データを扱う唯一のapplication targetである。`bqn-ledger`は互換性がないためreader、writer、fallbackとして使用しない。

`actual.journal`はh-kernel editorが読み書きする。他sourceはh-kernel operationをsourceごとに完成させる。未対応operationは暗黙fallbackせず停止し、必要な場合だけ明示的な手編集を行う。

write capability、安全なpublication、日常利用の完成は区別する。現在地と移行順は[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)、Editor境界は[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)が所有する。
