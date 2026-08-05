# h-kernel editor cutover readiness audit 001

ステータス: E8 readiness audit 001  
Owner: h-kernel editor cutover evidence  
基準日: 2026-08-06  
基準main: `a7c749aa74048289cfe4be598240536a800fc315`

## Scope

この文書は、`h-kernel` editorへ正規writer authorityを移せるかを判断するため、`SOURCE_DATA_MIGRATION_PLAN.md`の10個のcutover gateを現在のpublic `main`にあるcode、focused test、documentation、synthetic rehearsal evidenceへ対応付ける。

このsliceはreadiness auditだけを行う。

- docs-only
- private canonical sourceへaccessしない
- writer authorityを変更しない
- source format migrationを行わない
- bqn-ledger editorを停止しない
- E8 cutoverを実行しない

「機能が存在する」と「正規writerとして運用できる」を同一視しない。

## Verified repository state

GitHub remoteを基準に次を確認した。

- `main`: `a7c749aa74048289cfe4be598240536a800fc315`
- latest commit: `docs(editor): Actual add TUI rehearsal evidenceを記録する (#29)`
- latest commit changed files:
  - `docs/ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md`
  - `docs/INDEX.toml`
- open Pull Request: 0
- PR #28: merged as `f3536aa2389238d7ed2cb3dd8df06a896389f2a3`
- PR #29: merged as `a7c749aa74048289cfe4be598240536a800fc315`
- latest `main` CI: run #102, `SUCCESS`
- remoteに残る非main branchはPR #25から#29までのmerge済みhistorical branchであり、open sliceではない
- `ledger-data/`はpublic repository treeに存在しない
- latest diffとcurrent treeの確認では、private canonical source、backup、recovery workspace、machine-local absolute pathの公開を示す証拠は見つからなかった
- private repository名、private source path、private source内容は検索していない

最後のprivacy確認は、未知の秘密値が存在しないことを一般に証明するものではない。既知のpublic boundary、tree shape、latest diffに対する監査結果である。

## Current writer authority

```text
canonical source     separate private data repository
current writer       bqn-ledger editor
current readers      bqn-ledger and h-kernel
future writer        h-kernel editor after explicit cutover
```

`h-kernel-editor-cli --commit`とActual Add TUIのwrite pathが存在しても、明示的なcutover PRがmergeされるまでwriter authorityは移動しない。

## Evidence levels

gate判定では次を別の証拠levelとして扱う。

| Level | Meaning |
|---|---|
| Code | ownerとなるcode pathが存在する |
| Focused test | synthetic fixtureまたはfault injectionでcontractをtestしている |
| Synthetic observation | executableまたはTUIをsynthetic temporary sourceで操作した |
| Private non-canonical observation | private sourceの明示copyをcanonical directory外で操作した |
| Canonical operation | canonical sourceへの日常writeとして使用した |
| bqn semantic parity | 現在の日常writerとの観察可能な意味を比較した |
| Operational cutover | writer停止、source selection、rollbackを含めauthorityを移した |

`ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md`はSynthetic observationであり、Private non-canonical observation、Canonical operation、bqn semantic parity、Operational cutoverではない。

## Classification vocabulary

- **Satisfied**: gateの要求を現在のpublic evidenceで直接確認できる
- **Partially satisfied**:主要部分はあるがoperation範囲またはfailure evidenceが閉じていない
- **Not satisfied**:必要な能力またはcontractが存在しないことを確認した
- **Not yet evidenced**:能力の有無を断定せず、要求された比較または観察記録がない
- **Requires private non-canonical rehearsal**:public repository内では完了できないlocal evidenceが必要
- **Requires operational decision**:作者がwriter authority、source selection、停止、rollbackを決める必要がある

## Gate-by-gate evidence matrix

| # | Gate | Classification | Current evidence, owner, commit | Remaining condition |
|---:|---|---|---|---|
| 1 | Account、Actual、Plan、Budget、policy、notebook operation parity | **Partially satisfied** | Actual append: `HKernel.Editor.ActualAppend`, `EditorActualAppendSpec`, `3e21ca6`, `cde8d21`; reverse: `ActualReverse`, `EditorActualReverseSpec`, `39a5614`, `0a87f9e`; Account/Budget/Issue: named owners and focused specs, `e4731a2`, `12f6c3b`, `abcbe97`; Plan: `PlanLifecycle`, `EditorPlanLifecycleSpec`, `339d6af`, `8d33018`. Current CLI exposes Plan add and finish only. | operation inventoryを作り、bqn-ledgerの日常command vocabularyと照合する。正規計画が記すPlan editはcurrent module、CLI、testで確認できない。policy writeがcutover対象かuser-owned operationかも決定する。 |
| 2 | mutation前previewとstrict complete-source admission | **Satisfied** | `editor-app/Main.hs`は全commandでblock preview後にのみcommitする。各prepare ownerはcandidate complete sourceをstable parserへ戻す。`EditorActualAppendSpec`, `EditorActualAccountAppendSpec`, `EditorBudgetMovementAppendSpec`, `EditorIssueAppendSpec`, `EditorPlanLifecycleSpec`; `3e21ca6`, `89161c4`, `8d33018`. | gate自体はpublic code/focused evidenceで満たす。ただし正規運用済みを意味しない。 |
| 3 | stale source rejection | **Satisfied** | `ActualWriter.checkStaleAndWrite`; `EditorActualWriterSpec.testStaleReject`, `testActualBlockStaleReject`; TUI rehearsal Scenario C; `b1fd092`, `89161c4`, `1fb2007`, `a7c749a`. | canonical operationおよびprivate copy rehearsalはGate 7で別に扱う。 |
| 4 | atomic publishとpartial write不在 | **Partially satisfied** | `ActualWriter.withAtomicSwap`はsibling `.new.tmp`をwriteしてrenameし、success rehearsalではtemporary artifactが残らない。`EditorActualWriterSpec.testActualWrite`, `testPlanWrite`, `testActualBlockWrite`; `b1fd092`, `89161c4`, `1fb2007`, `a7c749a`. | write、rename、cleanupの各failure pointについてtargetがpartial candidateにならないことを明示したfault matrixがない。process crash durabilityやfilesystem前提をgate contractとして限定する必要がある。 |
| 5 | ignored backup、failure test、restore | **Partially satisfied** | `.gitignore`は`*.tmp`をignoreする。`ActualWriter.verifyOrRollback`と`restoreBackup`; `testPostAdmissionFailure`, `testPostPublishReadFailureRestores`, `testActualBlockPostAdmissionFailureRestores`; TUI focused recovery evidence; `b1fd092`, `89161c4`, `1fb2007`, `a7c749a`. | private non-canonical copyでbackup location、restore result、終了後artifactを確認する手順とevidenceがない。restore失敗時のoperator stop/verification手順も必要。 |
| 6 | duplicate identity、exact Quantity、Commodity別balance、provenanceの維持 | **Partially satisfied** | Account duplicate/round-trip: `EditorActualAccountAppendSpec`; Actual exact quantity/balance: `TransactionBlock`, `EditorActualAppendSpec`; reversal identity/provenance: `EditorActualReverseSpec`; Plan identity/completion: `EditorPlanLifecycleSpec`; `12f6c3b`, `5ed1287`, `0a87f9e`, `8d33018`. | 全operation横断inventoryとbqn semantic comparisonがない。multi-posting、multi-Commodity、Plan lifecycle、source placementを同一matrixで閉じる必要がある。 |
| 7 | synthetic sourceとprivate source copyを使った運用rehearsal | **Requires private non-canonical rehearsal** | Synthetic Actual Add TUI rehearsalは`ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md`に記録済み。`a7c749a`. | canonical directoryと物理分離したprivate non-canonical copyで、必要operation、failure、source diff、artifact、canonical untouchedを秘密なしで記録する。 |
| 8 | bqn-ledgerとのsemantic comparison | **Not yet evidenced** | `EDITOR_DEVELOPMENT_PLAN.md`と`SOURCE_DATA_MIGRATION_PLAN.md`は比較座標を定義するが、comparison matrix、harness、result reportはない。 | implementationを移植せず、command vocabulary、preview、placement、identity/provenance、exact Quantity、Commodity balance、stale、backup/restore、Plan、Account、Budget、Issue、failure、source selectionを比較する。 |
| 9 | dual writeを防ぐ運用変更 | **Requires operational decision** | `SECURITY.md`とmigration planはone-writer lawとdual write禁止を記す。 | bqn-ledger canonical write停止点、h-kernel source selection固定、同一directoryを両writerへ向けないguard、cutover中のtransaction freeze、rollback時の唯一writer、日常入口更新を決めて実装する。 |
| 10 | 作者による明示承認 | **Requires operational decision** | cutoverは明示承認が必要だと正規文書に記載済み。 | Gate 1から9がSatisfiedになった後、作者がcutover PRを明示承認する。今回の依頼はreadiness audit開始の承認であり、writer cutover承認ではない。 |

## Satisfied gates

Gate 2とGate 3は、current public code、focused tests、synthetic observationの範囲でSatisfiedと判定する。

この判定は次を意味しない。

- private non-canonical copyで観察済み
- canonical sourceで運用済み
- bqn-ledgerとのsemantic parity確認済み
- writer authority cutover済み

## Partial gates

Gate 1、4、5、6は主要なcodeとfocused evidenceを持つが、cutover全体として閉じていない。

特にGate 1には正規文書とcurrent mainの差がある。`EDITOR_DEVELOPMENT_PLAN.md`はPlan add、edit、finishをcurrent capabilityとして記すが、`HKernel.Editor.PlanLifecycle`、`HKernel.Editor.CLI`、`EditorPlanLifecycleSpec`で確認できるwrite operationはaddとfinishである。監査では存在しないoperationを推測でSatisfiedにしない。

Gate 4はrename-based publicationを確認できるが、すべてのfilesystem failure pointに対するpartial-write absenceをまだ証明していない。

Gate 5はrestore codeとfault testsを持つが、operator-facing restore/verification procedureとprivate copy evidenceがない。

Gate 6は個別contractが強い一方、全operation横断の意味保存表がない。

## Missing evidence

現時点で次のevidenceはない。

- current daily writerとのoperation parity inventory
- bqn-ledger semantic comparison matrixまたはharness
- private non-canonical copy rehearsal procedure
- private non-canonical copy rehearsal evidence
- operation横断のfailure matrix
- dual-write prevention contract
- source-selection cutover contract
- rollback contract
- explicit cutover approval

## Private non-canonical rehearsal requirements

private copy rehearsalはpublic GitHub workflow、public checkout、CIでは実行しない。先に独立したterminal/Codex実行指示書を作り、次を必須にする。

1. operatorがcanonical directoryとrehearsal directoryをlocal environmentで明示する。
2. `realpath`相当で両directoryが異なり、親子関係にもなく、rehearsal directoryがpublic checkout外であることを確認する。
3. rehearsal対象は明示したnon-canonical copyだけとし、canonical directoryを書込み可能なtarget argumentへ渡さない。
4. source本文、Account、Quantity、日付、Transaction、Plan、policy、note、absolute pathをstdout、CI、PR、Issue、public logへ出さない。
5. command resultは成功/失敗classと秘密を含まない件数だけ記録する。
6. rehearsal前後でcanonical sourceがuntouchedであることをlocal Git stateまたはcontent hashで確認する。値そのものは記録しない。
7. rehearsal copyでは各operationのsource diff、backup、temporary artifact、post-admission、restoreをlocalに確認する。
8. restore不完全または予期しないartifactがあれば停止し、canonical cutoverへ進まない。
9. evidence reportへprivate repository名、path、filename mapping、source snippet、hash値を記載しない。
10. copyの削除はdiffとartifact確認後にだけ行い、canonical sourceへcopy-backしない。

このaudit PRは実行指示書もrehearsalも実施しない。

## bqn-ledger semantic comparison requirements

比較対象はBQNのmodule構造ではなく、現在の日常writerとして観察可能な行動である。

| Coordinate | Required comparison |
|---|---|
| command vocabulary | 同じ日常operationが表現可能か |
| preview | mutation前にcandidateを確認できるか |
| source placement | metadata、posting order、空行、append/replace位置が意味を保つか |
| identity/provenance | durable identity、reverse relation、Plan completion relationを保つか |
| exact Quantity | decimalを丸めず同じQuantityとしてadmitするか |
| Commodity balance | Commodityごとのzero balanceを要求するか |
| stale rejection | preview後変更をwriteせず拒否するか |
| backup/restore | failure時のsource状態とoperator actionが同じ安全水準か |
| Plan lifecycle | add、select、edit、finish、completion observationの必要範囲 |
| Account declaration | identity、type、default Commodityを保つか |
| Budget movement | order、from/to、exact amountを保つか |
| Household Issue | optional amount、header、identity/statusを保つか |
| failure behavior | source内容を漏らさず有限な結果へ閉じるか |
| source selection | canonical directoryを暗黙推測せず一意に選ぶか |

synthetic corpusで双方のcandidateとadmitted semantic valueを比較し、raw textual equalityを唯一の基準にしない。private copy比較が必要な場合はGate 7のlocal safety procedureに従う。

## Dual-write prevention requirements

最終cutover前に、少なくとも次を一つのoperational contractへ固定する。

- bqn-ledger editorがcanonical writeを停止する具体的な時点
- h-kernel editorがcanonical sourceを選ぶ唯一の入口
- 両writerへ同じcanonical directoryを同時に渡さないguard
- cutover window中に未記帳transactionを一箇所へ集約する手順
- 同一transactionを両editorで再入力しない確認
- rollback時にbqn-ledgerまたはh-kernelのどちらか一方だけをwriterにする規則
- rollback後にwriter authority owner文書を戻す手順
- command documentation、日常launcher、source-selection documentationの切替
- cutover完了後のwriter authority owner文書更新

「h-kernel writeを有効にする」だけではGate 9を満たさない。

## Final cutover PR boundary

最終cutover PRへ含めるもの:

- bqn-ledger canonical write停止のoperational change
- h-kernel canonical source-selection入口
- dual-write prevention guardまたは明示的なmutual exclusion
- rollback authority contract
- command documentationと日常操作入口の切替
- writer authority owner文書の更新
- Gate 1から9の最終evidence参照と作者承認記録

最終cutover PRへ含めないもの:

- source format migration
- `accounts.tsv`などretained sourceのretire
- unrelated TUI expansion
- Report refactor
- generic editor framework
- private source内容
- bqn-ledgerの大規模cleanup
- 新しい会計意味論

## Proposed finite slices

依存順に次のsliceへ分ける。一度に複数を実装しない。

1. **E8a operation parity inventory**  
   h-kernelのcurrent code/CLI/testと、bqn-ledgerの日常operation vocabularyを表にする。Plan editとpolicy writeの要否を決定し、正規Editor planのcurrent capability表現を実装と一致させる。

2. **E8b bqn-ledger semantic comparison contract and harness**  
   synthetic corpus、semantic coordinates、result shape、秘密を保持しないdiagnosticを定義する。source format migrationは行わない。

3. **E8c private non-canonical copy rehearsal procedure**  
   canonical/non-canonical分離、出力抑制、artifact確認、canonical untouched確認を含むlocal-only実行指示書を作る。

4. **E8d private non-canonical copy rehearsal evidence**  
   E8cの手順を実行し、operation別の成功/失敗classと秘密を含まない件数だけを記録する。

5. **E8e publication failure matrix**  
   write、rename、post-read、post-admission、restore、cleanup failureを独立にcharacterizeし、partial targetとoperator stop conditionを固定する。

6. **E8f dual-write prevention contract**  
   bqn-ledger停止点、cutover window、single writer invariant、rollback ownerを決める。

7. **E8g cutover command and source-selection contract**  
   h-kernelの日常入口、source selection固定、canonical/rehearsal modeの区別を実装前に定義する。

8. **E8h rollback contract**  
   cutover failure時の唯一writer、source verification、authority document reversalを定義する。

9. **E8i explicit writer authority cutover PR**  
   Gate 1から9がSatisfiedであることを再確認し、作者の明示承認後にwriter authorityと日常入口だけを切り替える。

次のsliceはE8aとする。監査で見つかったoperation vocabularyの不一致を先に閉じない限り、comparison harnessの対象集合を確定できない。

## Explicit non-goals

- canonical sourceのreadまたはwrite
- private source copyの作成
- source migration
- writer authority cutover
- Plan editの実装
- policy writerの実装
- UI expansion
- Report変更
- generic framework
- bqn-ledger code移植
- historical branch削除
- mergeまたはReady化の自動実行

## Cutover stop condition

次のいずれかが残る間はcutoverを停止する。

- Gate 1から9に`Partially satisfied`、`Not satisfied`、`Not yet evidenced`、`Requires private non-canonical rehearsal`、`Requires operational decision`が一つでもある
- private non-canonical rehearsalでcanonical untouchedを確認できない
- bqn semantic comparisonでunexplained differenceがある
- restore失敗後のoperator actionが未定義
- bqn-ledger停止点とrollback writerが一意でない
- 作者がcutover PRを明示承認していない

このauditの結論は、`h-kernel` editorに有力なsafe writer部品とsynthetic evidenceが存在する一方、canonical writerへ切り替え可能とはまだ判定できない、である。
