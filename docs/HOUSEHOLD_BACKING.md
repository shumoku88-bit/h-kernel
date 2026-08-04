# Household Backing契約

ステータス: アクティブなdomain contract  
更新日: 2026-08-04

## 目的

この文書は、`HKernel.Household.Backing`が何を観察し、どの値を保持し、どこから先を推測しないかを所有する。

Backingは、Envelopeとして残っている家計上のclaimと、それを支えるpolicy指定Assetの残高を、一つの観察日に並べるprojectionである。

Backingは次ではない。

- 銀行口座内で資金が物理的に分離されているという主張
- 資金移動、支出、貯蓄、投資を命令する仕組み
- 異なるCommodityを換算する評価
- fixed obligationやreservation funding locationの暗黙の推論

## 入力の声部

```text
observation day + Period
HouseholdPolicy + BudgetPolicy
Journal Account balances
aligned Entitlement / Consumption / Remaining
HouseholdBudgetMovement facts
open HouseholdBackingPlan evidence
  -> Household Backing
```

### Policy

`BudgetPolicy`は次を所有する。

- spendable Envelope
- Envelopeが参照するBacking pool
- Backing poolに属するAsset Account

`HouseholdPolicy`は次を所有する。

- Envelopeの公開順
- Plan destinationからEnvelopeへの家計固有座標
- unassigned Budget Accountの範囲

Backing ownerはAccount名、残高、memoからこれらを推測しない。

### HouseholdBudgetMovement

`HKernel.Household.BudgetMovement`は、日付、memo、from Account、to Account、正確なAmountを持つsource-independentなfactである。

現在の`budget_alloc.tsv` rowは`HKernel.Household.BudgetMovement.TSV`でこの値へadmitされる。Backing計算はTSVの列形状やfile pathを知らない。

### Open Plan evidence

`HouseholdBackingPlan`は、lifecycleとPeriod選択を通過したopen outgoing Planのdestination Accountと、型で正を証明されたAmountを保持する。

Plan reserveはledger remainingと別の座標として残す。

## 公開する値

### EnvelopeBackingLine

一つのEnvelopeについて次を保持する。

- Entitlement
- Actual Consumption charges
- Actual Refunds
- Budget Remaining
- Open Plan Reserve

```text
Post-Plan Headroom
  = Budget Remaining - Open Plan Reserve
```

この値は将来支払うPlanを差し引いた説明用projectionであり、Journalへ自動記帳しない。

### EnvelopeBacking

一つの観察について次を保持する。

- half-open Period
- observation day
- EnvelopeごとのBacking line
- policy指定AssetのFunding Balance
- unassigned Budget ledger balance
- unassigned Expense evidence

## 集計規則

すべての計算はCommodityを分離した正確な`Balance`上で行う。換算、浮動小数点、暗黙の丸めは行わない。

### Signed Total

```text
Signed Total = foldMap Envelope Ledger Remaining
```

overspent Envelopeは負のまま残る。

### Backing Required

```text
Backing Required
  = foldMap positivePart Envelope Ledger Remaining
```

負のEnvelopeが別のEnvelopeの正のclaimを相殺することはない。

### Backing Surplus

```text
Backing Surplus
  = Funding Balance - Backing Required
```

負の結果は不足の証拠であり、失敗や自動調整ではない。

### Reconciliation Delta

```text
Reconciliation Delta
  = Backing Surplus - Unassigned Budget Balance
```

unassigned BudgetはEnvelope claimと混ぜず、別のledger evidenceとして最後に照合する。

## Stable ownerとadmission

`HKernel.Household.Backing`がmodelと計算を所有する。

`HKernel.Household.BudgetMovement.TSV`はretained sourceからsource-independent movementへのadmissionだけを所有する。Household Report compositionは同じ`HouseholdBudgetMovement`をEntitlementとBackingへ渡し、Backingの式、型、policy解釈を再実装しない。

## 現在の境界

現在のHousehold Reportは、policyで定義されたBacking poolのAssetを家計全体のFunding Balanceとして集約して公開する。pool別の不足と余剰を独立したsurfaceとして公開する設計は、現在の契約には含めない。

次はこの章で決めない。

- fixed obligation
- savingとして保護する額
- investmentへ移す予定額
- reservationがどのAsset locationですでにfundedか
- Backing pool別Report surface
- Commodity conversionや市場価値
- writer authority

これらを導入する場合は、既存Backing結果へ暗黙に混ぜず、明示的なpolicyまたは新しいprojectionとして観察する。

## 検証

`h-kernel-household-backing-test`がmulti-commodityな手作り証拠で次を検査する。

- signed totalが負のEnvelopeを保持する
- requiredが正のclaimだけを集める
- surplusがCommodityごとにfundingからrequiredを引く
- reconciliationがunassigned Budget evidenceを別に差し引く
- post-Plan headroomがledger remainingとreserveを区別する

既存Household Report testとcomplete report contractsは、stable ownerへの移動前後で現在の正規Report結果が変わらないことを検証する。
