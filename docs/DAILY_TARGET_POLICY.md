# Daily Target policyとcycle scope

ステータス: アクティブなdomain contract  
更新日: 2026-08-15

## 目的

Daily Targetは、観察日時点の対象Assetから、現在のcycleで差し引くopen Plan obligationの未予約部分を除き、cycle終端までの日数で割った正確なrateである。

この計算に使う値を、一枚のsourceに置かれているという理由で一つの意味へまとめない。

```text
eligible Asset policy
+ current-cycle obligation selection
+ bounded reservation evidence
+ observed balances
+ cycle boundary
-> Daily Target
```

## 三つの異なる意味

### Eligible Asset policy

日常支出へ使ってよいAsset Accountの集合である。

これは比較的長寿命の家計policyであり、Account名や残高、retired `accounts.tsv` metadataから推測しない。current canonical sourceでは `household.toml` の `[daily-target]` selection がこの座標を所有する。

`DailyTargetPolicy`は、参照する全Accountがcanonical `AccountRegistry`で宣言済みのAssetであることを検証してから構築される。

### Current-cycle obligation selection

どのoutgoing PlanをDaily Targetから差し引くかという、cycleごとに変化し得る明示的な選択である。

current canonical sourceでは `plan.journal` の transaction metadata が stable `PlanId` と Daily Target selection identity を結ぶ。Planが存在するだけでは自動的にDaily Targetへ入れない。

### Reservation evidence

一つの選択済みPlanについて、すでにDaily Target対象Assetの外へ除外済みの額を表すbounded evidenceである。

current canonical sourceでは同じ admitted Plan transaction の reservation metadata から `PlanReservationDeclaration` を構成し、`HKernel.Plan.Reservation` が次を検証する。

- durable reservation identity
- 既知Planへの参照
- 同じCommodity
- Plan amount以下の正量
- Planごとに高々一つのreservation

Daily Target ownerは、予約がどの口座へ置かれているかを推測しない。reservation funding locationは別policyである。

## Current source admission

canonical compositionは二つのownerを明示的に合わせる。

```text
household.toml
  -> [daily-target.assets]
  -> [DailyTargetAssetSelection]

plan.journal
  -> admitted Plan transaction metadata
  -> [DailyTargetObligationSelection]

selections + AccountRegistry + admitted outgoing Plans
  -> dailyTargetScopeFromSelections
  -> DailyTargetScope
```

`HKernel.Household.Application`がこのcompositionを行う。Account名、Plan表示text、現在のEnvelope assignmentからselectionを推測しない。

historical `daily_target_scope.tsv` は current canonical Household bootstrap ではない。2026-08-15 に `HKernel.Household.DailyTarget.TSV` compatibility adapter を build graph から撤去し、旧 TSV が検証していた semantic laws は current `household.toml + plan.journal` source path の tests へ移した。

この retirement は Daily Target の domain model を弱めない。source syntaxを外しただけで、selection identity、eligible Asset validation、known Plan validation、bounded reservation、partial reservation rejection は native owner に残る。

## Projection

`deriveDailyTarget`は次を受け取る。

- observation day
- current Period
- validated Journal
- DailyTargetScope
- current cycleのopen outgoing Plans

対象Asset残高、選択されたopen obligation、reservation deductionはそれぞれ`Balance`へprojectionされる。

```text
eligibleAssets      = foldMap accountBalance eligibleAccounts
openObligations     = foldMap planAmount selectedOpenPlans
alreadyExcluded     = foldMap reservationAmount selectedOpenPlans
capacity            = eligibleAssets - (openObligations - alreadyExcluded)
days                = max 1 (endExclusive - observedOn)
rate[commodity]     = capacity[commodity] / days
```

各Commodityは独立に保持され、換算や相殺を推測しない。Balance集計には`BALANCE_ALGEBRA.md`のlawfulなMonoidを使う。

## 保存する証拠

`DailyTarget`は最終rateだけでなく次を保持する。

- observation day
- cycle end exclusive
- eligible Asset aggregate
- open obligation aggregate
- already excluded reservation aggregate

これにより、Reportは最終値だけでなく控除の由来を説明できる。

## source boundary laws

- `household.toml` Asset selection identity と `plan.journal` obligation selection identity は同じ `DailyTargetScopeId` namespace を共有し、重複を fail closed する
- reservation metadata は selectionなしでは admission しない
- reservation id / amount / Commodity は部分指定を許さない
- eligible Account は canonical registry 上の Asset でなければならない
- selected PlanId は admitted outgoing Planへ解決できなければならない
- reservation Amount は対象 Plan の Amount を超えられない
- current configからhistorical Plan intentを再構成しない
- retired TSV syntaxをfallback readerとして再導入しない

## 非対象

このcontractは次を決めない。

- fixed obligation、saving、investmentをどう分類するか
- reservationがどのAsset Accountに置かれているか
- Daily Targetが負になった場合の助言またはUI
- Report composition全体のstable component移動

これらは別のpolicyまたはcomposition境界として扱う。
