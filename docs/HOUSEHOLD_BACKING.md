# Household Backing契約

ステータス: アクティブなdomain contract  
更新日: 2026-08-14

## 目的

この文書は、`HKernel.Household.Backing`が何を観察し、どの値を保持し、どこから先を推測しないかを所有する。

Backingは、Envelopeとして残っている家計上のclaimと、それを支えるpolicy指定Assetの残高・open Plan commitmentを、同じ観察日にBackingPoolごとに並べるprojectionである。

Backingは次ではない。

- 銀行口座内で資金が物理的に分離されているという主張
- 資金移動、支出、貯蓄、投資を命令する仕組み
- 異なるCommodityを換算する評価
- Account名やmemoからEnvelope intentを推測する仕組み

## ownerの分離

`HKernel.Backing`はsource shapeを知らない純粋なBackingPool算術を所有する。

一つのpoolについて、少なくとも次を別座標として保持する。

```text
Funding Balance
Funding Commitment
Gross Envelope Required
Available Envelope Required
Gross Surplus
Available Surplus
```

`HKernel.Household.Backing`は、admitted Household policy・Journal・Plan・Budget compatibility observationからこれらの座標を解決して`HKernel.Backing`へ渡すcomposition ownerである。pool算術を再実装しない。

## 入力の声部

```text
observation day + Period
HouseholdPolicy + BudgetPolicy compatibility
Journal Account balances
aligned Entitlement / Consumption / Remaining
HouseholdBudgetMovement facts
open HouseholdBackingPlan evidence
  -> pool-local native Backing
  -> Household Backing surface
```

### Policy

現在のcompatibility windowでは、`HouseholdPolicy`が保持するnative `BackingPolicy`（`HKernel.Backing.Policy`）が次を供給する。

- Envelope -> BackingPool
- BackingPool -> Asset Account membership

既存のcanonical `budget.toml` / `BudgetPolicy`からは`budgetPolicyBackingPolicy`による一方向のcompatibility projectionを通じてnative `BackingPolicy`が構成される。

`BackingPoolId`そのものは`HKernel.Backing.Identity`が所有し、native `BackingPolicy`およびcompatibility projectionは同じidentityを再利用する。

Household BackingはAsset Accountの名前や残高からpool membershipを推測しない。

### HouseholdBudgetMovement

`HKernel.Household.BudgetMovement`は、日付、memo、from Account、to Account、正確なAmountを持つsource-independentなfactである。

現在の`budget_alloc.tsv` rowは`HKernel.Household.BudgetMovement.TSV`でこの値へadmitされる。Backing計算はTSVの列形状やfile pathを知らない。

### Open Plan evidence

`HouseholdBackingPlan`はopen outgoing Planの次の二つのAccount座標を分けて保持する。

- source Account
- destination Account

source Assetは、policyのAsset -> BackingPool membershipを通じて`Funding Commitment`を作る。

```text
Available Funding
  = Funding Balance - Funding Commitment
```

Planのfunding horizonは「current Periodに日付が含まれるか」ではない。次Period境界より前に予定され、まだopenであるPlanはcommitmentであり、overdueになってもcompletion/cancellation等のlifecycle evidenceで閉じるまで残る。

```text
planned date < current period end-exclusive
```

このため、current period開始前のoverdue open PlanもBackingから消えない。

## Envelope claim

native Backing ownerへ渡すEnvelope claimは二つの量を保持する。

```text
Gross claim      = Remaining
Available claim  = Headroom
```

負のRemaining/Headroomはoverspending evidenceとして保持するが、別Envelopeの正のclaimを相殺してBacking Requiredを減らしてはいけない。

### 現在のcompatibility bridge

Household Report全体はまだ旧Budget observationから段階移行中である。そのため現在の`EnvelopeBackingLine`では一時的に、旧`plan-destination-accounts`のdestination Account lookupから`Open Plan Reserve`を作り、

```text
Headroom = Budget Remaining - Open Plan Reserve
```

としてnative Backingへ渡す。

これはnative Envelope intentではない。#250で確立したnative semanticsでは、non-Expense target fulfillment/commitmentのintent ownerはAccountではなくstable `PlanId`である。

従ってこのdestination lookupはmigration bridgeであり、新しいAccount-based authorityとして固定してはいけない。canonical Householdがnative `EnvelopeCommitment`へ接続された時点で削除する。

source Account -> BackingPool funding commitmentは、このlegacy destination lookupとは独立した意味である。

## BackingPool position

Household surfaceはpool別positionをaggregationより先に保持する。

```text
BackingPoolPosition
  pool id
  funding balance
  funding commitment
  gross envelope required
  available envelope required
  gross surplus
  available surplus
```

重要なlaw:

```text
pool A shortage + pool B surplus
```

を先に足して「家計全体では0」としてはいけない。pool Aの不足はpool Aの不足として観察可能でなければならない。

Household aggregate helperは表示・互換用summaryであり、pool-local adequacyのownerではない。

## Envelope compatibility detail

`EnvelopeBackingLine`は移行期間中、一つのEnvelopeについて次を保持する。

- Entitlement
- Actual Consumption charges
- Actual Refunds
- Budget Remaining
- Open Plan Reserve

```text
Post-Plan Headroom
  = Budget Remaining - Open Plan Reserve
```

この値はprojectionであり、JournalやEnvelope historyへ自動記帳しない。

## Household summary

aggregate helperは次を提供する。

```text
Funding Balance
  = foldMap pool Funding Balance

Backing Required
  = foldMap pool Gross Envelope Required

Backing Surplus
  = foldMap pool Gross Surplus

Available Backing Surplus
  = foldMap pool Available Surplus
```

これらは便利なsummaryだが、poolごとの不足/余剰を置き換えない。

`Signed Total`はEnvelopeのsigned Remainingをそのまま足すのでoverspending evidenceを負のまま保持する。

`Reconciliation Delta`は移行中のunassigned Budget ledger evidenceをGross Backing Surplusと別座標で照合する。

## exact arithmetic

すべての計算はCommodityを分離した正確な`Balance`上で行う。

- Commodity conversionをしない
- 浮動小数点を使わない
- 暗黙の丸めをしない
- JPY surplusでUSD shortageを相殺しない

## 現在の境界

この契約で確立済み:

- native `BackingPoolId`
- pool-local exact arithmetic owner
- native `HKernel.Backing.Policy`によるBacking座標（Envelope -> pool, Asset -> pool）の所有
- `Household.Backing` compositionがnative `BackingPolicy`から読むこと
- Household compositionがpool positionを保持すること
- Plan source Assetからpool funding commitmentを導くこと
- overdue open Planをcurrent funding horizonから落とさないこと
- aggregate summaryとpool-local adequacyを分けること

まだmigration中:

- Envelope claimのHousehold compositionは旧Budget Remainingを利用している
- Envelope Plan reserveは旧destination Account lookupをbridgeとして利用している
- `budget.journal` / `budget.toml` / `plan-destination-accounts`のcanonical source replacement

ここでは決めない:

- Commodity conversionや市場価値
- Asset -> BackingPool assignmentのhistorical source shape
- PlanId Fulfillment routingのphysical source shape
- writer authority for those future sources

## 検証

`h-kernel-backing-test`はpure native ownerについて次を検査する。

- matching/external funding commitments
- overspendingが正claimを相殺しないこと
- pool-local shortage
- multi-commodity exactness
- duplicate Envelope claim fail-closed

`h-kernel-household-backing-test`はHousehold surfaceについて次を検査する。

- signed Envelope evidence
- native pool positionsをaggregation前に保持すること
- gross/available summary
- source funding commitment後のavailable shortage
- 他poolのsurplusが不足poolそのものを消さないこと
- compatibility headroomとledger remainingの区別

Household Report lawは、open Plan sourceがBackingPool funding commitmentへ接続され、次Period境界までのoverdue/current open Planを同じfunding horizonとして扱うことを検証する。
