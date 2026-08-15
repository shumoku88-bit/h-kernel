# Household source admission inventory

ステータス: 現在状態の ownership inventory  
更新日: 2026-08-16

## 目的

この文書は、現在の `h-kernel` が一つの canonical `HouseholdRoot` から実際に読む source と、その admission owner を記録する。

migration history、retired compatibility source、writer authority は current reader topology へ混ぜない。shared canonical contract は [`HOUSEHOLD_CANONICAL_SOURCE.md`](HOUSEHOLD_CANONICAL_SOURCE.md)、source 別 writer authority は [`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md) が所有する。

## Canonical Household root

現在の application bootstrap が解決する source は次の8本である。

```text
accounts.journal
actual.journal
plan.journal
budget.journal
budget.toml
household.toml
report.toml
issues.tsv
```

basename の解決は `HKernel.Application.Config.householdSourcePaths` が一箇所で所有する。CLI、TUI、Report feature が個別に canonical basename を再定義しない。

```text
HouseholdRoot
  -> householdSourcePaths
  -> source-specific admission
  -> HouseholdState
  + exact mutable root bytes
  -> HouseholdWriteSnapshot
```

`HKernel.Household.Application.loadCanonicalHouseholdWriteSnapshot` が canonical observation boundary である。syntax ごとの owner を一つの generic parser へ畳まない。

## Current inventory

| Source | 現在の admission owner | typed output / role |
|---|---|---|
| `accounts.journal` | `HKernel.Account.Journal.parseAccountJournal` | `AccountRegistry` |
| `actual.journal` | `HKernel.Loader` root observation + `HKernel.Actual.Journal` | `ActualJournal` |
| `plan.journal` | `HKernel.Loader` root observation + `HKernel.Plan.Journal` | `PlanJournal` |
| `budget.journal` | `HKernel.Loader` root observation + `HKernel.Household.BudgetMovement` | `HouseholdBudgetMovementJournal` / ordered allocation movements |
| `budget.toml` | `HKernel.Envelope.Config.parseCurrentEnvelopeConfiguration` | `CurrentEnvelopePolicy` + `BackingPolicy` + `CurrentExpenseAssignments` |
| `household.toml` | `HKernel.Household.Config` + `HKernel.Household.EnvelopeHistory` | `HouseholdConfiguration` / `HouseholdPolicy` + historical routing owners |
| `report.toml` | `HKernel.Report.Config.parseReportConfiguration` | `ReportConfiguration` |
| `issues.tsv` | `HKernel.Household.Issue.TSV.parseHouseholdIssues` | `[HouseholdIssue]` |

`budget.toml` は `BudgetPolicy` aggregate を生成しない。Envelope definition、current Expense assignment、Backing topology は独立した typed owner として admit される。

`household.toml` の `[envelope-history]` は `HouseholdConfiguration` の opaque side fieldとして意味付けしない。同じ physical source から `HKernel.Household.EnvelopeHistory` が history を別 owner として admit する。

canonical private `household.toml` は既に `plan-destination-accounts` を保持しない。old sourceにこのretired keyが残る場合、`HKernel.Household.Config` はreader transition用のopaque compatibility inputとして受理するが、Account syntaxを再検証せず `HouseholdPolicy` に保存しない。non-Expense target のcurrent authorityはstable `PlanId` Fulfillment routingである。

`account-policy.budget.envelope-role` はcanonical admissionのrequired sectionではなく、存在しても `HouseholdAccountPolicy` へ投影しない。Budget movementのendpoint semanticsは `account-policy.budget.kind` が所有し、`opening` / `unassigned` / `spent` / `envelope` をnative Entitlement projectionが使用する。したがって `budget.kind` や `budget:spent` historical evidenceの退役をこの変更から推測しない。

Account registry は Actual、Plan、Budget Journal とcurrent policy上のAccount referenceを照合する。retired compatibility coordinateをopaqueに受理することから、新しいunknown semantic coordinateのsilent fallbackを認めない。

## Journal root observation

Actual、Plan、Budget は root `Text` を読んだ直後に別経路で同じ意味を再構成しない。

```text
exact root Text
  -> HKernel.Loader root observation
       -> resolved Journal
       -> root transaction-source evidence
  -> named domain admission
```

Budget Journal の resolved `Journal` と root transaction-source evidence は admission fence に使うが、admission後の `HouseholdBudgetMovementJournal` は ordered `HouseholdBudgetMovement` だけを保持する。parser-owned JournalをHousehold semantic stateへ二重保持しない。

Included Account declarations は resolved Journal へ寄与できる。一方、included transaction が root-local transaction のように紛れ込むことは count / semantic alignment fence で拒否する。

## HouseholdWriteSnapshot

`HouseholdWriteSnapshot` は current editor operation が publication に必要とする exact root bytes を、同じ typed Household observation と結びつけて保持する。

現在保持する root bytes:

- `accounts.journal`
- `actual.journal`
- `plan.journal`
- `budget.journal`
- `issues.tsv`

これは generic repository/session abstraction ではない。具体的な coordinated write が同一 observation を必要とする source だけを保持する。

`budget.journal` の exact root bytes は manual Budget movement publication の stale-source check と complete-source re-admission のために保持する。resolved Journal semantic stateを保持する理由にはしない。

## Retired migration sources

次の historical sources は current canonical bootstrap の入力ではない。

```text
accounts.tsv
plan.tsv
budget_alloc.tsv
cycle.tsv
config.tsv
daily_target_scope.tsv
legacy Report manifests
```

2026-08-15 時点で h-kernel の completed migration shell から次を撤去した。

- `HKernel.Household.AccountProfile.TSV`: `accounts.tsv` admission / Account Journal migration shadow
- `HKernel.Household.BudgetMovement.TSV`: `budget_alloc.tsv` admission
- Editor の arbitrary Budget TSV append fallback
- `HKernel.Household.DailyTarget.TSV`: `daily_target_scope.tsv` admission

`budget` Editor command は canonical `budget.journal` だけを mutation target とし、native `HouseholdBudgetMovementJournal` admission を通す。

この撤去は `budget.journal`、Budget `AccountType`、`budget:*` Account identity、`HouseholdBudgetMovement` の退役を意味しない。それらは current source / accounting vocabulary として別の責任を持つ。

他の `*.TSV` module が存在することから canonical bootstrap participation を推測しない。domain-specific history adapter や notebook syntax はそれぞれの owner と契約で判断する。

## Daily Target

`daily_target_scope.tsv` は current canonical Household bootstrap に存在せず、compatibility parser も current build graph から退役済みである。

Daily Target は `household.toml` から admit された Asset selection と `plan.journal` の typed Plan metadata / reservation evidence から `DailyTargetScope` を組み立てる。旧 TSV を canonical delivery path や diagnostic fallback へ併読しない。

旧 TSV が検査していた eligible Asset、known Plan、bounded reservation、selection identity uniqueness の laws は native source tests が所有する。

## Household Report

Household Report は `HouseholdState` の admitted owners から composition する。

```text
HouseholdState
  -> admitted Actual / Plan / Envelope / Backing / Issue inputs
  -> HKernel.Household.Report
  -> HouseholdReportSurface
  -> HKernel.Household.Report.Render
```

Report が source basename、retired TSV parser、Budget aggregate を再所有しない。

## 維持する境界

- exact Quantity / Commodity を保つ
- Account、Plan、Actual、allocation movement の identity / provenance を失わない
- canonical source の private ownership を変えない
- write capability から writer authority を推測しない
- `HouseholdWriteSnapshot` の同一 observation boundary を崩さない
- known retired compatibility keyのopaque admissionとunknown semantic coordinateのsilent ignoreを混同しない
- source-local failure を silent fallback へ変換しない
- generic source parser、generic repository/session、generic event frameworkを先回りして作らない
- completed migration adapter を「念のため」current application path へ戻さない
