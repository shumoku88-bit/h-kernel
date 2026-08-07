# Household Report スパイク境界

ステータス: アクティブな暫定境界  
更新日: 2026-08-07

## 目的

`HKernel.Spike.HouseholdReport`は、型付きdomain ownerと現在の互換sourceを合成し、`HouseholdReportSurface`を作るread-only adapterである。

一般Budget policy、Household policy、Daily Target、Household Backing、Budget movement admission、retained Account profile admissionは、すでにSpikeの外へ移った。Spikeが引き続き所有するのは、stable admission ownerが作る値をHousehold Reportへ合成するprovisional compositionと、source-local diagnosticへの翻訳であり、恒久的なapplication policy、domain policy、物理source parser、計算そのものではない。

## 現在の変換

```text
accounts.tsv
  -> HKernel.Household.AccountProfile.TSV
  -> RetainedAccountProfile
  -> Actual AccountRegistry parity

budget.toml
  -> HKernel.Budget.Config
  -> BudgetPolicy

household.toml + BudgetPolicy
  -> HKernel.Household.Config
  -> HouseholdPolicy
  -> AccountValidatedHouseholdPolicy

daily_target_scope.tsv
  -> HKernel.Household.DailyTarget.TSV
  -> DailyTargetPolicy
  + DailyTargetObligationScope
  -> DailyTargetScope

budget_alloc.tsv
  -> HKernel.Household.BudgetMovement.TSV
  -> HouseholdBudgetMovement

Actual Journal + Plan Journal
  + validated HouseholdPolicy
  + DailyTargetScope
  + aligned Budget results
  + HouseholdBudgetMovement
  -> Consumption / Entitlement / Remaining
  -> Household Backing / DailyTarget
  -> HouseholdReportSurface
```

現在、次の意味は名前付きownerへ委譲されている。

- retained Account profile classification: `HKernel.Household.AccountProfile`
- retained `accounts.tsv` admission and Actual registry parity: `HKernel.Household.AccountProfile.TSV`
- Plan identityと分類: `HKernel.Plan.Journal`
- Plan完了: `HKernel.Plan.Completion`
- 予約証拠: `HKernel.Plan.Reservation`
- 一般Budget policy: `HKernel.Budget.Policy`
- 一般Budget TOML admission: `HKernel.Budget.Config`
- Household policy: `HKernel.Household.Policy`
- Household TOML admission: `HKernel.Household.Config`
- Daily Target policyとprojection: `HKernel.Household.DailyTarget`
- retained Daily Target TSV admission: `HKernel.Household.DailyTarget.TSV`
- source-independent Budget movement fact: `HKernel.Household.BudgetMovement`
- retained Budget movement TSV admission: `HKernel.Household.BudgetMovement.TSV`
- Household Backing modelとprojection: `HKernel.Household.Backing`
- Consumption: `HKernel.Budget.Consumption`
- Entitlement: `HKernel.Budget.Entitlement`
- Remaining: `HKernel.Budget.Remaining`

`config.tsv`は現在のHousehold Report入力ではない。`HKERNEL_LEDGER_DATA_DIR`から受け取ったdirectoryの`actual.journal`をActual sourceとして読み、`ACTUAL_JOURNAL_FILE`をReport compositionで再確認しない。`HKernel.Application.Config`はcurrent Report boundaryから外れており、そのmodule、専用test、Cabal登録のretirementは別のcleanup sliceとして扱う。

## Policyの現在地

`budget.toml`は、家計に限らない次の意味を所有する。

- Envelope identity、label、pacing
- Expense Account assignment
- Backing pool
- Backing poolに属するAsset Account

`household.toml`は、その一般Budget policyへ次の家計固有座標だけを重ねる。

- income-anchor Cycle Account
- Envelopeの公開順
- Budget allocation AccountとEnvelopeの対応
- 追加のopen Plan destinationとEnvelopeの対応
- 未割当Budget Accountの範囲

```text
BudgetPolicy
  + Household coordinates
  -> HouseholdPolicy
       -> Cycle resolution
       -> Consumption / Entitlement / Remaining
       -> Backing
```

同じAccountや同じsource coordinateが同じEnvelopeを指すことは、冪等な一つのsemantic assignmentとして扱う。異なるEnvelopeを指す場合だけ衝突として拒否する。

Daily Targetは、物理sourceのrow形状とは別に次の意味へ分かれる。

- eligible Asset policy
- current-cycle outgoing Plan selection
- optional bounded reservation evidence
- observation dayとcycle boundaryから導くprojection

詳細は[`DAILY_TARGET_POLICY.md`](DAILY_TARGET_POLICY.md)が所有する。

Backingは、policy指定AssetのFunding Balance、Envelope claim、unassigned Budget evidence、open Plan reserveを別の座標として保持する。詳細は[`HOUSEHOLD_BACKING.md`](HOUSEHOLD_BACKING.md)が所有する。

`accounts.tsv`の`type`、`kind`、`budget`、`budget_group` metadataから、Report経路がBudget、Backing、Daily Target policyを再構成することはない。`HKernel.Household.AccountProfile.TSV`がAccount declarationとretained metadataをadmitし、Report経路はAccount identity、role、Commodityの互換確認を利用するだけである。

`cycle.tsv`はBQN互換sourceとして残るが、h-kernelのReport経路は参照しない。

## 残る暫定責任

- stable admission ownerが作る値を一つのHousehold Report surfaceへ合成すること
- AccountごとのCommodity policyの明示的な照合をReport compositionへ接続すること
- fixed obligation、saving、investment、reservation funding locationの恒久policyが未決定である状態を、既存source metadataから推測せず保つこと
- retained compatibility source群からstable Report inputへの境界をさらに狭めること
- Report compositionをstable Household componentへ移す条件を満たしたかを明示的に判定すること

これらが未解決の間、Report adapterは`Spike`名前空間を維持する。

## 開発規則

- 正規の家計Report結果を維持する
- Account名や残高からpolicyを推測しない
- 一般Budget意味をHousehold parserで再実装しない
- application source selectionをHousehold factへ混ぜない
- stable policy、current facts、Report projectionを区別する
- 新しいeffectやwriter authorityを暗黙に追加しない
- stable ownerに既にあるReport compositionやrenderingをSpikeで重複実装しない
- chapterごとに一つの到達点を持ち、節目で型・契約・実データを検証する
- 作業後にこの文書を現在へ同期し、完了済み説明は削除する

## Spikeを離れる条件

次が満たされたとき、Report compositionを安定したHousehold componentへ移す。

1. current-format admissionが名前付きstable ownerの背後にあり、Report compositionが物理parserを所有しない
2. 必須Commodity evidenceが明示的に照合される
3. Reportがfixed obligation、saving、investment、reservation funding locationを必要とする場合、その意味が明示的なpolicyとして存在する
4. Report input境界がstable typed valuesとして説明でき、compatibility sourceの物理形状をdomain contractにしない

Account profile admission、Daily Target policy、Household Backing、Budget movement admissionが名前付きownerを持つ条件は満たされた。Report composition自体のstable component移動は、上の残条件を満たす別sliceとして扱う。

writer cutoverは別の境界である。Spikeの卒業だけでは、h-kernelへ正規データの書込み権限を与えない。
