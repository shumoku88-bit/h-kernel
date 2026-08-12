# Actual Journal writer contract

ステータス: 承認済みcurrent contract  
Owner: `actual.journal` writer authority、daily Actual write operation、rollback boundary  
承認日: 2026-08-06  
更新日: 2026-08-12

## 1. Current authority

private canonical source set全体を一度に移行せず、`actual.journal`のwriter authorityだけを`bqn-ledger`から`h-kernel`へ移している。

```text
actual.journal
  canonical writer  h-kernel editor
  readers           h-kernel and bqn-ledger

other canonical source files
  writer authority  unchanged by this Actual-only cutover
```

`bqn-ledger`をreaderまたはReport engineとして使うことはできる。ただし、canonical `actual.journal`を変更する`bqn-ledger` operationは使用しない。

同じphysical directoryにある別sourceのwriter authorityは、この決定から推測して移さない。

## 2. Current daily operation

TTYの日常入口はworkspace-first `tools/hk`である。

```text
tools/hk
  no args         -> Actual workspace
  actual-add PATH -> same Actual workspace with an explicit Journal path
  actual-reverse  -> h-kernel editor reverse operation
  account         -> h-kernel editor Account declaration operation
  edit            -> explicit editor CLI route
```

`--base DIR`、`HKERNEL_LEDGER_DATA_DIR`、またはGit管理外の`ledger-data.local`がprivate source directoryを解決する。

ordinary Actual addは次の流れを使う。

```text
workspace
  -> typed Account selection or free-form input
  -> candidate preparation
  -> complete-source admission
  -> preview
  -> explicit confirmation
  -> safe writer
  -> post-admission
  -> fresh source reload
  -> workspace
```

`tools/hk`、Brick、CLIはAccount、Money、Transaction、Actual admission、source publication ruleを再実装しない。

Actual reverseは元Transactionを変更せず、新しいdurable `event-id`とexplicit `reverses` relationを持つinverse Transactionをappendする。詳細なidentity contractは[`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md)が所有する。

Budget movement、Issue、Plan sourceそのもののwriter authorityはこのcontractで変更しない。

## 3. Safe writer law

canonical Actual writeは既存safe writer boundaryを使う。

```text
expected old bytes
  + validated candidate bytes
  -> stale rejection
  -> backup
  -> sibling temporary file
  -> atomic publication
  -> post-admission
  -> success or restore-capable failure
```

次を守る。

- preview後にsourceが変わっていればwriteしない
- candidate complete sourceがstable admissionを通らなければwriteしない
- publication後のadmission failureをsuccessとして扱わない
- backup restore失敗時は通常operationを継続しない
- private source、backup、temporary artifact、path、hash、diagnostic本文をpublic Gitへ置かない

single-user operationではcross-process shared lockを必須にしない。代わりに、一つのcanonical writerだけを使い、stale checkでpreview後の変更を拒否する。

## 4. Single-writer law

```text
canonical actual.journal writer = h-kernel editor
bqn-ledger actual.journal write  = prohibited by operation
alternating dual write           = prohibited
reader compatibility             = separate concern
```

writer authorityは「その実装にwrite capabilityがあるか」とは別である。BQN側にwrite commandが残っていてもcanonical Actualには向けない。

## 5. Stop and recovery

次の場合は通常operationを止める。

- source admission failure
- stale rejection
- publication後のadmission failure
- backup restore失敗
- filesystem failure
- canonical writerが二つ存在する疑い

restore-capable failureでbackupが復元された場合も、原因を確認するまで次のwriteを行わない。restore失敗時はsourceを手動編集せず、canonical repositoryの現在値、backup、writer artifactを保全して調査する。

## 6. Rollback

rollbackは`bqn-ledger`への自動fallbackではない。

1. `h-kernel`と`bqn-ledger`の両writer operationを停止する
2. canonical `actual.journal`のcurrent bytesを保全する
3. `h-kernel`のstrict Actual admissionと必要なreader compatibilityを確認する
4. 未完了previewまたはpublicationがないことを確認する
5. 作者がwriter authorityの再移動を明示承認する
6. authority文書を更新した後にだけ旧writerを再開する

source rollbackとwriter authority rollbackを暗黙に同時実行しない。

## 7. Reader compatibility

writer cutoverとreader compatibilityは別の問いである。

ordinary Actual addは既存Journal意味を保つ。Haskell-native reversalはexplicit `reverses` provenanceを持つため、BQN readerを同じcanonical sourceへ向け続ける場合は、そのadmission対応を別sliceとして確認する。

reader compatibilityのためにHaskell writerのidentity contractを弱めない。

## 8. Non-goals

- private source format migration
- `accounts.tsv`、Plan、Budget、Issue sourceのwriter cutover
- dual write
- BQN readerの削除
- shared lock
- private evidenceのpublic upload
- source本文を使うpublic fixture作成

## 9. Related owners

- [`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md): current Editor capability、workspace、safe writer law
- [`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md): source別writer authority、single-writer law、cutover gate
- [`HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md): current canonical reader topology
- [`ARCHITECTURE.md`](ARCHITECTURE.md): componentとeffect boundary
- [`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md): reversal identity contract
