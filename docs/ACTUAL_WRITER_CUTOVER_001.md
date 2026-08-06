# Actual Journal writer cutover 001

ステータス: 承認済みcutover contract  
Owner: `actual.journal` writer authority、daily Actual add operation、rollback boundary  
承認日: 2026-08-06

## 1. Decision

private canonical source set全体を一度に移行せず、`actual.journal`のwriter authorityだけを`bqn-ledger`から`h-kernel`へ移す。

```text
actual.journal
  canonical writer  h-kernel editor
  readers           h-kernel and bqn-ledger

other canonical source files
  writer authority  unchanged by this cutover
```

このcutover後、`bqn-ledger`をreaderまたはReport engineとして使うことはできる。ただし、canonical `actual.journal`を変更する`bqn-ledger` operationは使用しない。

同じphysical directoryにある別sourceのwriter authorityは、この決定から推測して移動しない。

## 2. Initial daily operation set

最初の日常operation setは小さく保つ。

- ordinary Actual addは`h-kernel-editor-tui`を使う
- 日常入口は`tools/hk actual-add <ACTUAL_JOURNAL>`とする
- Reportは既存`tools/hk`または`tools/hk report ...`を使う
- correctionが必要な場合は元Transactionを編集せず、`h-kernel`のActual reverse contractを使う
- Account declarationまたはPlan finishが必要な場合は、canonical `actual.journal`へ書く唯一のwriterとして`h-kernel` editor operationを使う

Budget movement、Issue、Plan sourceそのもののwriter authorityはこのcutoverで変更しない。

## 3. Evidence

### 3.1 Public synthetic evidence

`main`のsafe writer testは、independent synthetic sourceを使って少なくとも次を観察する。

- ordinary publication success
- stale source rejection
- post-admission failure後のbackup restore
- post-publish read failure後のbackup restore
- confirmed Actual block publication
- confirmed Actual block stale rejection
- invalid confirmed Actual blockのrestore

command hub verifierは、argument preservation、exit status、unknown command rejectionをsynthetic stubで観察する。このcutover sliceはActual add TUI routingとpath arity rejectionを追加する。

### 3.2 Private non-canonical rehearsal

作者が2026-08-06に、private canonical sourceの明示的なcopyだけを対象として次をlocalに確認した。

```text
source resolution: success
copy isolation: success
preview: success
preview left copy unchanged: yes
commit: success
post-write admission: success
writer temporary artifacts: absent
canonical source unchanged: yes
repository files changed: no
canonical writer authority changed during rehearsal: no
```

これは作者から報告されたsanitized operational evidenceである。Account、date、Quantity、Commodity、description、path、hash、source本文はpublic repositoryへ記録しない。

### 3.3 Semantic boundary

既存のActual semantic comparison evidenceは、BQN candidateとHaskell candidateをstrict admission後のTransaction、identity、reversal provenanceで比較する。

ordinary Actual addのsemantic parityと、Haskell-native reversalが持つexplicit provenance differenceを混同しない。

## 4. Activation procedure

このcontractを含むPRがmergeされた後、operatorは次の順序でactivationする。

1. `bqn-ledger`による進行中のcanonical write operationがないことを確認する
2. `h-kernel`のlocal `main`を最新merge SHAへfast-forwardする
3. private source directoryを`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`で明示する
4. canonical sourceをread-onlyでReport admissionし、失敗時はwriteを開始しない
5. `actual.journal`の最初のwriteを次のentrypointからpreviewする
6. previewを確認し、TUIの別confirmation段階で明示承認する
7. publicationとpost-admission successを確認する
8. 以後、canonical `actual.journal`へ`bqn-ledger` writerを向けない

```sh
./tools/hk actual-add "$HKERNEL_LEDGER_DATA_DIR/actual.journal"
```

`tools/hk`はsource selection、candidate preparation、admission、publicationを再実装しない。explicit pathを既存TUIへ渡すだけである。

## 5. Single-writer law

cutover後のlawは次である。

```text
canonical actual.journal writer = h-kernel editor
bqn-ledger actual.journal write  = prohibited by operation
alternating dual write           = prohibited
reader compatibility             = separate concern
```

single-user operationではcross-process shared lockを必須にしない。代わりに、旧writerを使わないというoperation boundaryを明示し、各write前にcurrent sourceを読み直す。

TUI preview後にsourceが変わった場合、safe writerはstaleとして拒否する。stale outcomeの後はTUIを終了し、current sourceを読み直してpreviewからやり直す。

## 6. Stop and recovery

次の場合は通常operationを止める。

- source admission failure
- stale rejection
- publication後のadmission failure
- backup restore失敗
- filesystem failure
- canonical writerが二つ存在する疑い

restore-capable failureでbackupが復元された場合も、原因を確認するまで次のwriteを行わない。restore失敗時はsourceを手動編集せず、canonical repositoryの現在値、backup、writer artifactを保全して調査する。

private source、backup、temporary artifact、path、hash、diagnostic本文をpublic GitHubへ置かない。

## 7. Rollback

rollbackは`bqn-ledger`への自動fallbackではない。

1. `h-kernel`と`bqn-ledger`の両writer operationを停止する
2. canonical `actual.journal`のcurrent bytesを保全する
3. `h-kernel`のstrict Actual admissionと必要なreader compatibilityを確認する
4. 未完了previewまたはpublicationがないことを確認する
5. 作者がwriter authorityの再移動を明示承認する
6. authority文書を更新した後にだけ旧writerを再開する

source rollbackとwriter authority rollbackを暗黙に同時実行しない。

## 8. Non-goals

- private source format migration
- `accounts.tsv`、Plan、Budget、Issue sourceのwriter cutover
- dual write
- BQN readerの削除
- shared lock
- private evidenceのpublic upload
- source本文を使うpublic fixture作成

## 9. Completion condition

このcutoverは、PR mergeだけではlocal machine上でactivationされない。

次の両方が成立した時点でoperation上の切替完了とする。

- このcontractとdaily entrypointが`main`へmergeされている
- operatorがactivation procedureを実施し、最初のcanonical Actual addでpublicationとpost-admission successを確認している
