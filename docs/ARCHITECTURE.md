# h-kernel アーキテクチャ

ステータス: アクティブな正規architecture

## 1. この文書の役割

この文書は、`h-kernel`の安定したcomponent境界、依存方向、会計上の不変条件、effectの置き場所を所有する。

editorの現在地は[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)、canonical Household source shapeとcurrent reader topologyは[`HOUSEHOLD_CANONICAL_SOURCE.md`](HOUSEHOLD_CANONICAL_SOURCE.md)、writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。`actual.journal`のsource-specific cutoverは[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

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
  owns: Account, Money, Ledger, Journal, Actual, Plan,
        Engine, Report, rendering primitives, application config admission

h-kernel-household
  source: household-src/
  depends on: h-kernel
  owns: HouseholdPolicy, DailyTarget, HouseholdBacking,
        BudgetMovement, Household Issue admission, Household Report

h-kernel-household-application
  source: household-app-src/
  depends on: h-kernel + h-kernel-household
  owns: canonical Household admission, HouseholdWriteSnapshot,
        admitted Household Report composition entrypoint

h-kernel-editor
  source: editor-src/
  depends on: h-kernel + h-kernel-household
  owns: typed edit intent, pure candidate preparation, source placement,
        complete-source admission, stale check, backup, atomic publication,
        post-admission and restore-capable writer result
```

Delivery adapterはlibraryとは別に置く。CLI/TUI/shell routerへ会計ruleやwriter lawを複製しない。

このcomponent一覧は現在の意味を説明する地図であり、layer数やmodule数を維持するための設計目標ではない。既存ownerの直接な関数と値で十分な処理にwrapper、context、service、generic helperを追加しない。新しい境界は、実在するdomain invariant、lifecycle、dependency direction、effect ownershipのいずれかを明瞭にするときだけ導入する。

一時的なcompatibility aliasや移行用moduleは、callerがstable ownerへ移った後にarchitectureとして保存しない。安全性を保つための型は残すが、型で保証済みの意味をdelivery層や別wrapperで儀式的に再表現しない。

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

`Commodity`はvalidated text identityであり、fiat currencyやISO codeの閉じた列挙ではない。表示名、symbol、locale、fraction digitsはpresentation policyであり、Commodity identityを変更しない。

`Quantity`は`Scientific`による正確な10進数として保持する。`Amount`は一つの`Commodity`におけるnative magnitudeであり、異なるCommodityを一つの数値へ暗黙変換しない。個々のAccount declarationはdefault Commodityを明示的constraintとして持ち得て、`Journal` admissionがその一致を検証する。ただしそのAccount-level constraintを理由に`Commodity`型そのものを閉じたcurrency universeへ変えない。

Quantityとvaluationは別の意味である。将来reporting valueや換算が必要になっても、元`Amount`を書き換えず、explicit price evidenceとvaluation policyからProjectionとして導出する。Commodity identity、price observation、valuation policy、lot identityを一つの型や設定へ潰さない。

### 5.2 Balance

`Balance`はCommodityごとのQuantityを保持するopaqueなcanonical valueであり、zero entryを持たない。

`Semigroup` / `Monoid`はBalance contributionの結合を所有する。Transaction、Journal、Plan lifecycleなど、順序、identity、provenanceを持つ値へ同じinstanceを機械的に広げない。

### 5.3 Account

Accountの意味は名前から推測しない。`AccountRegistry`と検証済みdeclarationがAccount identity、`AccountType`、optional default Commodityを所有する。

UIでも表示Textをidentityとして使わずtyped `Account`を保持する。現在のlabelやdescriptionをdurable external identity、counterparty identity、historical relationの代用にしない。

### 5.4 Transaction

`Transaction` constructorは公開しない。admissionは少なくともdescription、2+ Postings、declared Account、exact Quantity/Commodity、Commodityごとのzero balanceを保証する。

Account、Posting、Transactionは会計Factとして小さく保つ。将来のimport、statement、document、counterparty、workflow都合だけでoptional fieldをcore primitiveへ蓄積しない。gross / net / fee / taxのような会計上のmovementは、必要なAccountと複数Postingで表現できる限りTransaction metadataへ重複保存しない。

### 5.5 Actual identityとreversal

Actualのdurable identityとreversal relationは`HKernel.Actual.Journal`がadmitする。reversalは元Transactionを変更せず、新しいdurable `event-id`とexplicit `reverses` relationを持つinverse Transactionとして追加する。

### 5.6 Fact、Policy、Projection

永続的な意味をFact / Declaration、Policy / Decision、Projectionへ分ける。

- **Fact / Declaration** はadmitされた出来事、identity、参照証拠である。Transaction / Posting grain、source order、exact Amount / Commodity、identity、provenanceを必要なconsumerが失わず参照できる形に保つ。
- **Policy / Decision** はFactそのものではない分類、選択、割合、method、観察条件である。意味が時間で変わり得る場合はeffective-dated evidenceとして表し、current policyからhistorical meaningを逆算しない。
- **Projection** はFact / Declaration / Policyから純粋に導出されるBalance、Report、lifecycle stateなどである。Projection都合でFactを書き換えず、再生成可能な値を重複canonical authorityとして保存しない。

Posting-grainの集計viewを作ることはよいが、それだけを唯一のFact ownerにしてTransaction boundaryやsource orderを回復不能にしない。Reportにおける具体的なfact grainとprojection ownershipは[`REPORT_PIPELINE_POLICY.md`](REPORT_PIPELINE_POLICY.md)が所有する。

Durable relationは明示的なtyped identity / evidenceで表し、description、日付、金額の近似一致をauthorityにしない。この区分はJournalをappend-only event storeへ変更せず、universal event typeも要求しない。

計算lawも区別する。Balanceのような順序不変のcontributionは可換なreductionとして結合できる。一方、Plan lifecycle、routing history、correction chainなど過去のstateとordered evidenceに依存する計算は順序を保持するtransitionとして扱う。どちらもfoldに見えるという理由だけで同じgeneric frameworkへ統一しない。

### 5.7 External evidence

Bank row、card statement、CSV feed、OCR / AI extraction、document metadataなど外部から得たobservationはcandidate evidenceであり、それだけではcanonical Actual factではない。Canonical sourceへ入るにはnamed admission ownerを通り、identity / provenance / validationを明示する。

Ledgerから導出した`Balance`と、statement等が主張するexternal balanceも別の意味である。照合機能を追加する場合は両者を比較し、不一致をfail closedに扱う。差分を消すためだけのbalancing Transactionを自動生成してFactを書き換えない。

External evidenceやworkflow capabilityはcore accounting primitiveへoptional fieldとして埋め込むのではなく、具体的なownerが必要になった時点でtyped relation / admission / projectionとして隣接させる。

## 6. Report and Household projections

Reportはvalidated factsから作るpure projectionである。合計はCommodity別の`Balance`を保ち、unknown classificationやunassigned evidenceを黙って消さない。

Household policy、Daily Target、Backing、Budget movement、Issueはそれぞれnamed ownerが意味を所有する。Household Reportのstable ownerは`HKernel.Household.Report`と`HKernel.Household.Report.Render`であり、canonical Householdからのcomposition entrypointは`HKernel.Household.Application`が所有する。

## 7. Dependency direction

```text
h-kernel-household             -> h-kernel
h-kernel-household-application -> h-kernel + h-kernel-household
h-kernel-editor                -> h-kernel + h-kernel-household
report app                     -> admitted report owners
editor adapters                -> h-kernel-editor
tools/hk                       -> existing adapters / checks
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

source別authority、single-writer law、cutover gateは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。safe publication lawは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)とEditor implementation ownerが所有する。`actual.journal`のactivation、stop、rollbackは[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。
