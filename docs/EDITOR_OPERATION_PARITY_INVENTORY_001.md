# h-kernel / bqn-ledger editor operation parity inventory 001

ステータス: E8a operation parity inventory 001  
Owner: editor operation vocabulary and coexistence boundary  
基準日: 2026-08-06  
基準 h-kernel main: `efe96f26aa3d07d72134f442b6151e21699b3664`  
基準 bqn-ledger main: `e35203c856ef27fed52dfe955825472104823198`

## Scope

この文書は、writer cutover readiness audit 001が次のfinite sliceとして定めたE8aを実施する。

- current public `bqn-ledger` editorの日常operation vocabularyを列挙する
- current public `h-kernel` editorのoperation vocabularyと照合する
- operationごとにsemantic owner、physical source、write/read-onlyの別、parity状態を記録する
- 移行初期にBQN editorとHaskell editorの両方を使えるようにするという作者決定を記録する
- 両editor併存と、無調整な同時writeを区別する
- 後続のsemantic comparison、shared serialization、private rehearsalの対象集合を確定する

このsliceはdocs-only inventoryである。

- private canonical sourceへaccessしない
- private repository名、path、内容、履歴を検索しない
- canonical sourceへwriteしない
- writer authorityを変更しない
- shared lockをまだ実装しない
- source format migrationを行わない
- BQN codeをHaskellへ移植しない
- UIを変更しない

## Verified remote state

GitHub remoteを基準に次を確認した。

### h-kernel

- `main`: `efe96f26aa3d07d72134f442b6151e21699b3664`
- latest merged PR: #30 `docs(editor): writer cutover readinessを監査する`
- open PR: 0
- current Editor CLI:
  - Actual append
  - Actual reverse
  - Account declaration append
  - Budget movement append
  - Issue append
  - Plan add
  - Plan finish

### bqn-ledger

- `main`: `e35203c856ef27fed52dfe955825472104823198`
- latest main change is the accounting review cursor in `TODO.md`; editor files were not changed by that commit
- open PR #546 is a debt Account classification documentation slice and does not overlap this editor inventory
- stable public editor surface: `tools/edit`
- active write path: `tools/edit-bqn` plus `src_edit` and `tools/lib/safe-write.sh`

## Author decision: initial dual-editor availability

移行初期は、BQN editorとHaskell editorの両方を利用可能にする。

この決定は、次を意味する。

```text
one canonical source set
multiple available editor implementations
one write transaction at a time
one shared serialization contract
no copy synchronization
no last-writer-wins
```

「両方のeditorを使える」と「同じsourceへ競合する二つのwriter authorityを置く」は同じではない。

writer authorityは、特定の実装名だけではなく、canonical sourceへwriteを許可する共有された運用contractとして扱う。BQNとHaskellのどちらを選んでも、そのcontractの内側で一つずつwriteする。

このinventoryだけではcanonical dual-editor operationを許可しない。shared serialization、semantic comparison、private non-canonical rehearsalが完了するまで、現行のcanonical writer境界は変わらない。

## Coexistence law

両editor併存では、少なくとも次を満たす。

1. 両editorは同じcanonical source rootを明示的に選ぶ。editor別copyを同期しない。
2. previewはsnapshotから生成してよいが、commit時には共有source-root lockを取得する。
3. lock取得後、operationが触る全sourceを再読し、preview作成時のexact snapshotと一致することを確認する。
4. staleならwriteせず、lockを解放し、新しいpreviewからやり直す。
5. backup、candidate publish、post-admission、必要なrestoreが終わるまでlockを保持する。
6. Plan finishなど複数sourceの意味を読むoperationは、fileごとの独立lockではなくsource-root単位で直列化する。
7. lock取得失敗、lock protocol不一致、restore不完了ではfail closedする。
8. lock artifact、backup、recovery workspace、local pathをpublic Git、CI、Issue、PRへ出さない。
9. 同じTransaction、Plan completion、Budget movement、Issueを両editorへ二重入力しない。
10. 一方のeditorがwriteした後、もう一方は必ず最新sourceをadmitしてから次のpreviewを作る。

shared lockの物理方式とlauncher統合はE8f相当の別sliceで決める。

## Classification vocabulary

- **Overlap candidate**: 両editorに同じsemantic operationがあり、同じphysical sourceへ収束できる。semantic comparisonとshared serialization後にdual-editor候補となる。
- **Source-topology blocked**: semantic operationは両方にあるが、現在のauthoritative physical sourceが異なる。二sourceを同時に正本化してはならない。
- **BQN-only retained**: current dailyまたはmaintenance operationがBQN側にだけある。移行初期はBQN editorを残す理由になる。
- **Read-only dependency**: write primitiveではないが、selection、preview、interactive workflowに必要なread surfaceである。
- **Out of editor parity**: user-owned policyまたはexecution configurationであり、今回のeditor write parityから除外する。
- **Needs observation**: operation名は対応しても、rendered bytes、identity、metadata、failure behaviorのparityがまだ証拠化されていない。

## Operation inventory

| Domain | Operation | bqn-ledger current surface / physical owner | h-kernel current surface / physical owner | Classification | Coexistence decision |
|---|---|---|---|---|---|
| Account | add declaration | `account add` writes retained `accounts.tsv` | `account` appends an Account directive to an Actual Journal | **Source-topology blocked** | 同じAccount meaningを二つのcanonical sourceへ書かない。Account source authorityまたはdeterministic projectionを先に決める。 |
| Account | list/select | `account list` read-only selector | dedicated selectorなし | **Read-only dependency** | 移行初期はBQN selectorを利用できる。Haskell TUI parityは別slice。 |
| Actual | ordinary two-posting add | `journal add` writes configured native Actual Journal | `append` writes Actual Journal transaction block | **Overlap candidate / Needs observation** | exact Quantity、Commodity default、metadata、identity、description、source placementを比較する。 |
| Actual | general multi-posting add | `journal multi-add` writes one native transaction | `append` accepts a non-empty posting list and validates balance | **Overlap candidate / Needs observation** | 2 posting以上、multi-Commodity rejection、zero、precision、renderingを比較する。 |
| Actual | list/select | `journal list` read-only transaction export | dedicated selectorなし | **Read-only dependency** | reverse UIでは当面BQN selectorを利用できる。 |
| Actual | reverse | `journal reverse` selects by indexまたはidentity and appends reversal | `reverse` accepts explicit new identity and target identity and appends reversal | **Overlap candidate / Needs observation** | target selection、new identity、provenance metadata、description、sign inversionを比較する。 |
| Actual | cleanup plan/apply | BQN cleanup commands exist as maintenance operations | operationなし | **BQN-only retained** | daily editor parityから分離する。必要性とauthorityをmaintenance sliceで決める。 |
| Budget | add movement | `budget add` appends retained Budget movement source | `budget` appends `budget_alloc.tsv` movement | **Overlap candidate / Needs observation** | date、memo、from/to、Quantity、Commodity、row order、duplicate behaviorを比較する。 |
| Plan | list/select | `plan list` exports open Plan candidates | selectorなし | **Read-only dependency** | 移行初期はBQN selectorを利用できる。 |
| Plan | related selection | `plan related` owns recurring relation-key semantics | operationなし | **Read-only dependency** | replenishment UIはBQN側を維持する。 |
| Plan | add | `plan add` writes retained `plan.tsv` and generates `plan_id` | `plan add` writes native Plan Journal and generatesまたはadmits `plan-id` | **Source-topology blocked** | `plan.tsv`とPlan Journalを両方canonicalにしない。Plan source migration/parityを先に閉じる。 |
| Plan | finish | `plan finish` reads `plan.tsv` and appends `plan_id` Actual; optional orchestration may add next Plan | `plan finish` reads Plan Journal and appends `plan-id` Actual | **Source-topology blocked** | Actualだけ同じでもPlan lookup ownerが異なるため、canonical coexistence対象にまだ入れない。 |
| Plan | edit | `plan edit` exact-replaces date/amount of an open retained Plan | operationなし | **BQN-only retained** | 初期併存ではBQN editorを残す。native Plan editの要否と意味を別sliceで決める。 |
| Plan | budget companion sync | `plan budget-sync` idempotently appends missing execution-envelope companion | operationなし | **BQN-only retained** | recoverable saga semanticsを比較対象に追加する。 |
| Issue | add | `issue add` appends `issues.tsv` with open/resolved/dropped vocabulary | `issue` appends `issues.tsv` with open/resolved vocabulary and optional Amount pair | **Overlap candidate / Needs observation** | schema、header、新規file、identity uniqueness、status vocabulary、optional Amountを比較する。 |
| Issue | list/select | `issue list` read-only export | selectorなし | **Read-only dependency** | close UIではBQN selectorを維持する。 |
| Issue | close/drop | `issue close` exact-replaces an existing open row | append operationのみ。resolved rowの新規appendはcloseと同義ではない | **BQN-only retained** | Haskell側にexact lifecycle operationができるまでBQNを残す。 |
| Travel | friend pending event add | dedicated `travel friend add` source event | operationなし | **BQN-only retained** | current h-kernel native target外。BQN専用source ownerとして保持し、Actualへ暗黙投影しない。 |
| Travel | exchange event add | dedicated `travel exchange add` two-amount source event | operationなし | **BQN-only retained** | current h-kernel native target外。rateやJournal factへ暗黙変換しない。 |
| Policy | Budget / Household policy edit | source is user-owned TOML or retained compatibility policy | automated policy writerなし | **Out of editor parity** | 当面はuser-owned manual edit。Account/Plan/Actual writer parityへ混ぜない。 |
| Report | manifest / execution config edit | retained bqn-ledger execution configuration | writerなし | **Out of editor parity** | household fact editor cutoverのgateに数えない。 |

## Same-physical-source pilot candidates

最初のdual-editor private rehearsal候補は、現在のoperation shapeから次に限定する。

1. Actual ordinary add
2. Actual multi-posting add
3. Actual reverse
4. Budget movement add
5. Issue add

これはcanonical writeの許可ではない。各operationに次のevidenceが揃った後、private non-canonical copyで試す候補集合である。

- same input intentのsemantic comparison
- candidate bytesまたはadmitted valueの比較
- identity/provenance comparison
- stale conflict comparison
- backup、post-admission、restore comparison
- shared source-root serialization
- cross-editor alternating write scenario

Account addとPlan lifecycleは、physical source authorityが異なるためpilotから除外する。

## Required alternating-write scenarios

private non-canonical copy rehearsalでは、単独editor successだけでなく、次の交互操作を観察する。

### Scenario A: BQN then Haskell

1. BQNでoperation 1をpreviewしてcommitする。
2. Haskellが最新sourceを再admitする。
3. Haskellで異なるoperation 2をpreviewしてcommitする。
4. complete-source admission、identity uniqueness、artifact absenceを確認する。

### Scenario B: Haskell then BQN

Scenario Aの順序を逆にする。

### Scenario C: stale preview conflict

1. editor Aがpreviewを作る。
2. editor Bが別operationをcommitする。
3. editor Aの古いpreview commitを拒否する。
4. editor Aがfresh previewを作り直すと成功可能であることを確認する。

### Scenario D: lock contention

1. editor Aがshared source-root lockを保持する。
2. editor Bのcommitは待機または明示拒否し、sourceを変更しない。
3. lock release後、editor Bはfresh snapshotでのみcommitできる。

### Scenario E: post-admission failure and restore

1. editor Aがpublish後の検証失敗を起こす。
2. shared lockを保持したままrestoreする。
3. editor Bはrestore完了前にwriteできない。
4. restore後のsourceがpre-write admitted valueへ戻ることを確認する。

## Semantic comparison coordinates

operationごとに少なくとも次を比較する。

- selected physical source
- accepted date grammar
- Quantity exactness and precision
- Commodity resolution and declaration requirement
- Account admission
- balance by Commodity
- zero handling
- description and memo preservation
- metadata key spelling and ordering
- identity generationまたはexplicit identity admission
- duplicate identity rejection
- Plan completion provenance
- row/block placement and trailing newline
- preview meaning
- stale token meaning
- backup location class
- atomic publication boundary
- post-admission scope
- restore refusal when a later writer changed the source
- error class without private values

raw textが異なってもsemantic parityを満たす場合と、byte parityがUI contractとして必要な場合を分けて記録する。

## Findings

### 1. Plan editの欠落はconfirmed gap

BQN daily surfaceには`plan edit`があり、Haskell current CLI、PlanLifecycle owner、focused testsには対応operationがない。

### 2. policy writerはinitial parity対象ではない

`budget.toml`、`household.toml`などのpolicyはuser-owned manual sourceとして残す。両editorがpolicy writerになる必要はない。

### 3. dual-editor availabilityはoperation単位で開く

全commandを一度に二重化しない。同じphysical source、semantic comparison、shared serializationが揃ったoperationだけをdual-editor候補へ昇格する。

### 4. source topology mismatchはcommand parityより先に解く

AccountとPlanは、command名が対応していてもcurrent physical sourceが異なる。両方へwriteするadapterは正本を増やすため採用しない。

### 5. stale checkだけではshared serializationにならない

両実装が個別にstale checkを持っていても、check後からrenameまでのcross-process競合を共通に閉じる証拠はない。canonical dual-editor operationには、両者が同じprotocolで参加するsource-root serializationが必要である。

## Gate effect

`EDITOR_CUTOVER_READINESS_AUDIT_001.md`のGate 1とGate 9を次のように具体化する。

- Gate 1 operation parity:
  - inventoryは完了
  - overlap candidateのsemantic comparisonは未完了
  - Plan edit、Plan budget-sync、Issue close、travel eventはHaskell gapまたはexplicit retained BQN operation
  - AccountとPlanはsource-topology decisionが未完了
- Gate 9 dual-write prevention:
  - 作者決定は「initial dual-editor availability」
  - 禁止対象はeditor実装の複数存在ではなく、無調整なparallel write、copy sync、last-writer-wins
  - shared serialization contractと実装は未完了

したがってGate 1とGate 9はまだSatisfiedではない。

## Next finite slice

次はE8b semantic comparison contract and synthetic harnessとする。

最初の対象はActual addとActual reverseに限定する。

- BQN implementationをportしない
- 同じsynthetic sourceとintentから観察可能なsemantic coordinateを比較する
- private canonical sourceを使わない
- shared lock実装はまだ行わない
- Account/Plan source migrationを混ぜない

E8bでcomparison contractを固定した後、Budget addとIssue addへ広げる。shared source-root serializationは別のcoherent sliceで実装する。

## Stop condition

このinventoryは、次を満たした時点で完了とする。

- current BQN daily operation vocabularyが列挙されている
- current Haskell operation vocabularyとの対応が記録されている
- read-only selectorとwrite primitiveが分離されている
- same-source overlapとsource-topology mismatchが分離されている
- initial dual-editor availabilityの意味が明示されている
- unsafe parallel write、copy sync、last-writer-winsが禁止されている
- next semantic comparison targetが有限に定まっている
