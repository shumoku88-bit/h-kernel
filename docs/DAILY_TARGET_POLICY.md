# Daily Target policyとcycle scope

ステータス: アクティブなdomain contract  
更新日: 2026-08-04

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

これは比較的長寿命の家計policyであり、Account名や残高、`accounts.tsv`の自由metadataから推測しない。`DailyTargetPolicy`は、参照する全Accountがcanonical `AccountRegistry`で宣言済みのAssetであることを検証してから構築される。

### Current-cycle obligation selection

どのoutgoing PlanをDaily Targetから差し引くかという、cycleごとに変化し得る明示的な選択である。

Planが存在するだけでは自動的にDaily Targetへ入れない。選択された`PlanId`がadmitted outgoing Planへ解決できることを検証する。

### Reservation evidence

一つの選択済みPlanについて、すでにDaily Target対象Assetの外へ除外済みの額を表すbounded evidenceである。

予約relationの検証は`HKernel.Plan.Reservation`が所有する。

- durable reservation identity
- 既知Planへの参照
- 同じCommodity
- Plan amount以下の正量
- Planごとに高々一つのreservation

Daily Target ownerは、予約がどの口座へ置かれているかを推測しない。reservation funding locationは別の未解決policyである。

## Current source admission

`daily_target_scope.tsv`は互換sourceとして残る。現在は一枚の表に次のrowを持つ。

- `asset`: eligible Asset policy coordinate
- `obligation`: Plan selectionとoptional reservation declaration

`HKernel.Household.DailyTarget.TSV`がこの物理形状を読み、次へ分離する。

```text
daily_target_scope.tsv
  -> DailyTargetPolicy
  + DailyTargetObligationScope
  -> DailyTargetScope
```

source pathとwriter authorityはこの章で変更しない。TSVの物理形状はdomain modelの形を決定しない。

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

## 非対象

このcontractは次を決めない。

- fixed obligation、saving、investmentをどう分類するか
- reservationがどのAsset Accountに置かれているか
- `daily_target_scope.tsv`のwriter cutover
- Daily Targetが負になった場合の助言またはUI
- Report composition全体のstable component移動

これらは別のpolicyまたはcomposition境界として観察する。
