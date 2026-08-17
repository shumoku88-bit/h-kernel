# Household Backing契約

ステータス: アクティブな domain contract  
更新日: 2026-08-17

## 目的

この文書は、`HKernel.Household.Backing` が何を観察し、どの native value を組み合わせ、どこから先を推測しないかを所有する。

Backing は、Envelope として残っている家計上の claim と、それを支える policy 指定 Asset の残高・open Plan funding commitment を、同じ観察日に BackingPool ごとに並べる projection である。

Backing は次ではない。

- 銀行口座内で資金が物理的に分離されているという主張
- 資金移動、支出、貯蓄、投資を命令する仕組み
- 異なる Commodity を換算する評価
- Account 名や memo から Envelope intent を推測する仕組み
- retired `BudgetPolicy` / `BudgetRemaining` aggregate の別名

## owner の分離

`HKernel.Backing` は source shape を知らない pure BackingPool 算術を所有する。

一つの pool について次を別座標として保持する。

```text
Funding Balance
Funding Commitment
Gross Envelope Required
Available Envelope Required
Gross Surplus
Available Surplus
```

`HKernel.Household.Backing` は admitted Household policy、Journal facts、native Envelope projections、open funding Plan evidence を解決して `HKernel.Backing` へ渡す composition owner である。pool 算術を再実装しない。

## Current inputs

```text
observation day + Period
Journal Account balances
BackingPolicy
Envelope identities
EnvelopeEntitlement
EnvelopeConsumption
EnvelopeRemaining
EnvelopeHeadroom
open HouseholdBackingPlan funding evidence
  -> pool-local native Backing
  -> Household Backing surface
```

旧 `BudgetPolicy`、旧 `BudgetObservation`、旧 Account-based Plan destination lookup は current input ではない。

### BackingPolicy

`HKernel.Backing.Policy` が次を所有する。

- Envelope -> BackingPool
- BackingPool -> Asset Account membership

canonical `envelope.toml` は `HKernel.Envelope.Config.parseCurrentEnvelopeConfiguration` を通じて native `BackingPolicy` を直接 admit する。`BudgetPolicy` compatibility aggregate を経由しない。

Household Backing は Asset Account の名前や残高から pool membership を推測しない。

### Open Plan funding evidence

`HouseholdBackingPlan` は open outgoing Plan の **source Account と positive Amount** を保持する。

source Asset は `BackingPolicy` の Asset -> BackingPool membership を通じて Funding Commitment を作る。

```text
Available Funding
  = Funding Balance - Funding Commitment
```

Plan の funding horizon は「current Period の開始日以後か」ではない。次 Period 境界より前に予定され、まだ open である Plan は commitment であり、overdue になっても lifecycle evidence で閉じるまで残る。

```text
planned date < current period end-exclusive
```

この funding commitment は Envelope fulfillment routing とは独立した座標である。

## Envelope claim

native Backing owner へ渡す Envelope claim は二つの量を保持する。

```text
Gross claim      = EnvelopeRemaining
Available claim  = EnvelopeHeadroom
```

負の Remaining / Headroom は overspending evidence として保持するが、別 Envelope の正の claim を相殺して Backing Required を減らしてはいけない。

`EnvelopeBackingLine` は presentation detail として次を並べる。

- Entitlement
- Actual Consumption charges
- Actual Refunds
- native Remaining
- Open Plan Reserve

ここで `Open Plan Reserve` は legacy destination Account lookup ではない。

```text
Open Plan Reserve
  = native Remaining - native Headroom
```

Headroom 自体は stable PlanId fulfillment routing を含む native Envelope projection から受け取る。Backing が Plan destination Account から Envelope intent を再構成しない。

## Unassigned attention と unmanaged

`EnvelopeConsumption` の `unrouted` evidence は `envelopeUnassignedExpenses` として surface に残す。

explicit `NotEnvelopeManaged` は `unrouted` と同一視しない。Envelope 管理外と明示された Expense を unassigned attention へ混ぜない。

この区別は current Expense routing authority から導かれ、Backing が Account 名や current config から historical intent を推測し直さない。

## BackingPool position

Household surface は pool 別 position を aggregation より先に保持する。

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

重要な law:

```text
pool A shortage + pool B surplus
```

を先に足して「家計全体では0」としてはいけない。pool A の不足は pool A の不足として観察可能でなければならない。

aggregate helper は表示・summary 用であり、pool-local adequacy の owner ではない。

## Household summary

aggregate helper は次を提供する。

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

`Signed Total` は Envelope の signed Remaining をそのまま足すので overspending evidence を負のまま保持する。

## exact arithmetic

すべての計算は Commodity を分離した正確な `Balance` 上で行う。

- Commodity conversion をしない
- 浮動小数点を使わない
- 暗黙の丸めをしない
- JPY surplus で USD shortage を相殺しない

## 現在の境界

確立済み:

- native `BackingPoolId`
- native `BackingPolicy`
- native `EnvelopeEntitlement`
- native `EnvelopeConsumption`
- native `EnvelopeRemaining`
- native `EnvelopeHeadroom`
- pool-local exact arithmetic
- stable PlanId fulfillment semantics と Backing の source-Asset funding commitment の分離
- overdue open Plan を funding horizon から落とさないこと
- aggregate summary と pool-local adequacy の分離

current architecture に存在しない bridge:

- `BudgetPolicy` -> Backing projection
- legacy `BudgetRemaining` -> Envelope claim
- destination Account -> Envelope Plan reserve lookup
- `budget_alloc.tsv` -> canonical movement admission
- `budget.journal` / `budget.toml` -> legacy source bridge

ここでは決めない:

- Commodity conversion や市場価値
- Asset -> BackingPool assignment の historical source shape
- writer authority の将来変更

## 検証

`h-kernel-backing-test` は pure native owner について次を検査する。

- matching / external funding commitments
- overspending が正 claim を相殺しないこと
- pool-local shortage
- multi-commodity exactness
- duplicate Envelope claim fail-closed

`h-kernel-household-backing-test` と Household Report の laws は次を検査する。

- signed native Envelope evidence
- charges / refunds
- unrouted attention
- unmanaged Expense を attention に混ぜないこと
- native pool positions を aggregation 前に保持すること
- gross / available summary
- source Asset funding commitment
- overdue/current open Plan の funding horizon
- 他 pool の surplus が不足 pool そのものを消さないこと
