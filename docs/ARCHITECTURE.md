# h-kernel アーキテクチャ

ステータス: アクティブな正規architecture  
更新日: 2026-08-11

## 1. この文書の役割

この文書は、`h-kernel`の安定したcomponent境界、依存方向、会計上の不変条件、effectの置き場所を所有する。

editorの現在地は[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)、writer authorityは[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)と[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

## 2. Functional coreと明示的なeffect boundary

`h-kernel`は複数のpure componentと狭いdelivery adapterから構成する。

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

pure coreはfile path、process exit、interactive event loop、atomic renameを会計計算へ持ち込まない。effect boundaryは、外界との接触をdomain calculationから分離する。

## 3. Current components

```text
h-kernel
  source: src/
  owns: Account, Money, Ledger, Journal, Actual, Plan, Budget,
        Engine, Report, rendering primitives, application config admission

h-kernel-household
  source: household-src/
  depends on: h-kernel
  owns: HouseholdPolicy, DailyTarget, HouseholdBacking,
        BudgetMovement, Household Issue admission

h-kernel-editor
  source: editor-src/
  depends on: h-kernel + h-kernel-household
  owns: typed edit intent, pure candidate preparation, source placement,
        complete-source admission, stale check, backup, atomic publication,
        post-admission and restore-capable writer result
```

Delivery adapterはlibraryとは別に置く。CLI/TUI/shell routerへ会計ruleやwriter lawを複製しない。

## 4. Effectの所有者

### 4.1 Journal load

`HKernel.Journal`のparserとinclude解決はpureである。`HKernel.Loader`はfilesystem上のinclude graphを読むadapterである。load後のAccount validation、Transaction validation、集計、Report projectionはpure ownerへ戻す。

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

CLIやTUIはこの順序を複製しない。UI stateへcomplete private source、backup、writer authorityを持ち込まない。

### 4.3 Application and terminal

report app、editor app、Brick TUI、shell launcherは引数、環境変数、標準入出力、終了状態、terminal eventを扱う。会計ruleやsource admissionをadapter都合で再実装しない。

## 5. Domain invariants

### 5.1 QuantityとCommodity

Quantityは`Scientific`による正確な10進数として保持する。`Amount`は必ず一つの`Commodity`を持つ。異なるCommodityを一つの数値へ暗黙変換しない。

### 5.2 Balance

`Balance`はCommodityごとのQuantityを保持するopaqueなcanonical valueであり、zero entryを持たない。

`Semigroup` / `Monoid`はBalance contributionの結合を所有する。Transaction、Journal、Plan lifecycleなど、順序、identity、provenanceを持つ値へ同じinstanceを機械的に広げない。

### 5.3 Account

Accountの意味は名前から推測しない。`AccountRegistry`と検証済みdeclarationがAccount identity、`AccountType`、optional default Commodityを所有する。

UIでも表示Textをidentityとして使わずtyped `Account`を保持する。

### 5.4 Transaction

`Transaction` constructorは公開しない。admissionは少なくともdescription、2+ Postings、declared Account、exact Quantity/Commodity、Commodityごとのzero balanceを保証する。

### 5.5 Actual identityとreversal

Actualのdurable identityとreversal relationは`HKernel.Actual.Journal`がadmitする。reversalは元Transactionを変更せず、新しいdurable `event-id`とexplicit `reverses` relationを持つinverse Transactionとして追加する。

## 6. Report and Household projections

Reportはvalidated factsから作るpure projectionである。合計はCommodity別の`Balance`を保ち、unknown classificationやunassigned evidenceを黙って消さない。

Household policy、Daily Target、Backing、Budget movement、Issueはそれぞれnamed ownerが意味を所有する。

## 7. Dependency direction

```text
h-kernel-household -> h-kernel
h-kernel-editor    -> h-kernel + h-kernel-household
report app         -> admitted report owners
editor adapters    -> h-kernel-editor
tools/hk           -> existing adapters / checks
```

禁止:

- `h-kernel`から`h-kernel-editor`への依存
- `h-kernel-household`からeditorへの依存
- Report ownerからfilesystem writerへの依存
- Render ownerからsource readへの依存
- delivery adapterへの会計rule / mutation ruleの移動
- UI toolkit型のshared domain ownerへの流入

## 8. Writer authority

componentにwrite capabilityが存在することとcanonical writer authorityは別である。

source別authority、activation、single-writer law、stop、rollbackは[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)、[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)、[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。
