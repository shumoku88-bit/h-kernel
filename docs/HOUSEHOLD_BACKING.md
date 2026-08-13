# Household Backing契約

ステータス: アクティブなdomain contract  
更新日: 2026-08-14

## 目的

この文書は、`HKernel.Household.Backing`が何を観察し、どの値を保持し、どこから先を推測しないかを所有する。

Backingは、Envelopeとして残っている家計上のclaim、policy指定Assetのfunding、まだopenなPlan commitmentを、同じHousehold observation上で比較するprojectionである。

Backingは次ではない。

- 銀行口座内で資金が物理的に分離されているという主張
- 資金移動、支出、貯蓄、投資を命令する仕組み
- 異なるCommodityを換算する評価
- Liability残高から将来のcash paymentを推測する仕組み
- PlanをActualやBudget Remainingへ書き込む仕組み

## 三つの声部

```text
Actual
  Asset / Liability / Expense の現実

Budget
  Entitlement / Consumption / Remaining のcontrol ledger

Plan
  まだ起きていないopen commitment
```

これらを一つの値へ潰さない。

特に次はstable lawである。

```text
Budget Remaining
  = Entitlement - Actual Consumption
```

Plan commitmentは`Budget Remaining`を変更しない。その上のavailable projectionとして差し引く。

## Policy座標

`BudgetPolicy`は次を所有する。

- Envelope
- Envelope -> BackingPoolId
- Asset Account -> BackingPoolId

`HouseholdPolicy`は次を所有する。

- Envelopeの公開順
- Plan destination -> Envelopeの家計固有relation
- unassigned Budget Accountの範囲

意味はAccount名、memo、残高から推測しない。

```text
Account      = 資金がどこにあるか
Envelope     = 何のために使えるclaimか
BackingPool  = どのfunding locationを相互に代替可能として扱うか
```

## Open Plan evidence

`HouseholdBackingPlan`は、lifecycle qualificationを通過したopen outgoing Planの次を保持する。

- source Account
- destination Account
- 型で正を証明されたAmount

sourceとdestinationを一つの「予算科目」へ潰さない。一つのPlanは独立に次の二つを作りうる。

```text
source Asset -> BackingPool commitment
destination  -> Envelope commitment
```

source Assetがpolicy上のBackingPoolへ属さなければ、pool commitmentを推測しない。destinationがEnvelopeへrouteされなければ、Envelope commitmentを推測しない。

### Commitment horizon

current Household observationでfundingを拘束するのは、open outgoing Planのうち次のincome-anchorより前に支払うべきものとする。

```text
committedPlanDate < current Period.endExclusive
```

したがって、

- current cycle開始前でもstill-openなoverdue Planは拘束を続ける
- current cycle内のopen Planは拘束する
- 次のincome-anchor当日以降のPlanは次cycle側で扱う

期限が過ぎただけでopen obligationを自由資金へ戻さない。解放はcompletion / cancellation / supersessionなどlifecycle evidenceが所有する。

Liability残高そのものからcash claimは作らない。将来のLiability settlementがfundingを拘束するなら、その約束はopen Planとして明示される。

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

`Budget Remaining`はledger fact、`Post-Plan Headroom`はplanning projectionであり、別の座標である。

### BackingPoolBacking

一つのBackingPoolについて次を保持する。

- Gross Funding Balance
- Open Plan Funding Commitment
- Gross Envelope Required
- Available Envelope Required

```text
Available Funding
  = Gross Funding - Pool Commitment

Gross Surplus
  = Gross Funding - Gross Envelope Required

Available Surplus
  = Available Funding - Available Envelope Required
```

通常のEnvelope支払Planはsource側fundingとdestination側claimを同額拘束しうる。このとき同じcommitmentを二重控除しない。

Envelope外のfixed obligationやLiability settlement Planは、destinationがEnvelopeへrouteされない限りfunding側だけを拘束する。

### EnvelopeBacking

一つの観察について次を保持する。

- half-open Period
- observation day
- EnvelopeごとのBacking line
- BackingPoolごとのBacking fact
- unassigned Budget ledger balance
- unassigned Expense evidence

Household aggregateはpool-local factsから導くsummaryである。aggregateが0でも、あるpoolの不足と別poolの余剰が相殺されている可能性があるため、**aggregateからpool-local adequacyを推論してはならない**。

## Reconciliation

unassigned Budgetは、funding residualそのものではない。Budget ledger上で明示された別のcontrol evidenceとして保持する。

```text
Reconciliation Delta
  = Gross Household Backing Surplus
  - Ledger Unassigned
```

これはpool-local adequacyの代替ではない。

## Commodity

すべての計算はCommodityを分離した正確な`Balance`上で行う。

- 暗黙のFX換算をしない
- 浮動小数点を使わない
- 異Commodityの不足と余剰を相殺しない

## Stable ownerとadmission

`HKernel.Household.Backing`がmodelと純粋計算を所有する。

Household Report compositionは、admitted Actual / Budget / Plan / Policyから必要なfactを選び、このownerへ渡す。Backing owner自身はsource file、TOML、TSV、Plan lifecycle publicationを知らない。

SPARKや別engineへ渡す場合も、証明層にAccount名やsource選択を再実装させない。proof boundaryへ渡すのは、既にadmitされたpool / envelope / commodity / amount座標とする。

## 現在あえて決めないこと

次はこの契約で暗黙に固定しない。

- BackingPool間のcross-pool Planを許可するpolicy
- cycle終了時のEnvelope claim rollover policy
- FX valuation
- 市場価値
- writer authority

必要になった場合は、現在の座標を潰さず新しいpolicyまたはattention projectionとして追加する。

## 検証

`h-kernel-household-backing-test`は少なくとも次を検査する。

- signed Remainingがoverspentを負のまま保持する
- gross requiredはpositive claimだけを集める
- matching pool/envelope commitmentを二重控除しない
- Envelope外commitmentはfunding側だけを拘束する
- 別poolの余剰がpool-local shortageを消さない
- reconciliationはLedger Unassignedを別のevidenceとして扱う
- post-Plan headroomとledger Remainingを区別する

Household Report testは、overdue still-open Planが次のincome-anchorまでcommitmentとして残り、next-cycle Planがcurrent fundingを先取りしないことを検査する。
