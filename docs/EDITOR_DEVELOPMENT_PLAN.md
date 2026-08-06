# h-kernel Editor 開発設計面

ステータス: アクティブな正規開発設計面  
Owner: h-kernel editor  
Canonical: yes  
更新日: 2026-08-06  
更新条件: editorのmain能力、daily-use入口、writer authority、cutover gate、次の有限sliceが変わるとき

## 1. この文書の役割

この文書は、`h-kernel` editorの現在能力、component境界、write effect、writer cutoverまでの次の一歩を所有する。

過去のE番号、branch、commit、完了PRの履歴はGitが所有する。この文書には、現在mainで使えるもの、まだ使えないもの、次に検証する一つの有限sliceだけを置く。

## 2. CURRENT

```text
canonical source     separate private data repository
current writer       bqn-ledger editor
current readers      bqn-ledger and h-kernel
h-kernel role        report engine + explicit editor + daily command hub
writer cutover       not performed
```

`h-kernel`には現在、次のcomponentとentrypointがある。

```text
h-kernel-editor
  source: editor-src/
  owns: intent, candidate preparation, source placement,
        complete-source admission, safe writer result

h-kernel-editor-cli
  source: editor-app/
  owns: argument boundary, preview, explicit --commit, exit status

h-kernel-editor-tui
  source: editor-tui-app/
  owns: Actual add interaction and explicit confirmation

tools/hk
  owns: report / edit / check / help routing only
```

### 2.1 Current editor operations

CLIは現在、次のnamed operationを公開する。

- Actual ordinary append
- Actual native multi-posting append
- Actual reversal
- Account declaration append
- Budget movement append
- Household Issue append
- Plan add
- Plan finish

Plan editはcurrent CLI operationではない。BQN editorに存在する全operationを移植済みとは扱わない。

### 2.2 Preview and admission

すべてのwrite candidateは、source mutation前にpreviewされる。

```text
explicit source path
  + typed intent
  -> pure candidate fragment
  -> candidate complete source
  -> stable complete-source admission
  -> preview
  -> optional explicit commit
```

candidate fragmentだけを正しいと見なさない。Account、Money、Transaction、Actual metadata、Plan、Budget movement、Issueは、それぞれのstable ownerへ戻してcandidate complete sourceを検証する。

### 2.3 Safe writer

source publicationは既存safe writerが所有する。

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

CLI、TUI、command hubはこの処理を複製しない。

- preview後にsourceが変わっていればwriteしない
- domain admissionが失敗した場合はsourceへ触れない
- publish後のadmission failureでは通常運用を継続しない
- backup、temporary file、recovery artifact、private sourceをGitへ入れない
- focused testとpublic CIはsynthetic sourceだけを使う

### 2.4 Actual reversal

Actual reverseは元Transactionを変更せず、新しいTransactionをappendする。

- postingsを順序とCommodityを保ってexactに反転する
- reversalは新しいdurable `event-id`を持つ
- `reverses` metadataでtargetを明示する
- unknown target、self-reference、duplicate direct reversalを拒否する
- reverse-of-reverseは新しいexplicit edgeとして許可する

詳細は[`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md)が所有する。

### 2.5 Actual add TUI

TUIはActual addだけを扱うdelivery adapterである。

- Account selectionとpositive magnitude inputをpure interaction stateへ渡す
- existing `prepareActualAppend`でcandidateを作る
- candidateをpreviewする
- explicit confirmation後だけexisting safe writerへ渡す
- stale、success、restore済みfailure、未復旧failure、filesystem failureを有限なoutcomeとして表示する

TUIはcomplete private source、backup、会計計算、writer authorityを所有しない。

### 2.6 Daily command hub

`tools/hk`は日常入口としてmainへmerge済みである。

```text
tools/hk
  -> report
  -> edit
  -> check
  -> help
```

- 引数なしは既存report launcherへ委譲する
- `report`は既存report entrypointへ引数を渡す
- `edit`は`h-kernel-editor-cli`へ引数を渡す
- `check`はrepository標準build、test、ownership auditを呼ぶ
- command hub自身はsourceを読まず、書かず、会計計算をしない

## 3. Single-user writer law

このprojectのcanonical editorは一人のoperatorが順番に使う。

cross-process shared lock、二つのeditorによるalternating canonical write、lock contention testはcutover要件にしない。

```text
before cutover
  canonical writer = bqn-ledger
  h-kernel write = synthetic or explicit non-canonical rehearsal only

after explicit cutover
  canonical writer = h-kernel
  bqn-ledger writer is not used against canonical source
```

writerを切り替えるときは旧editorの操作を終え、新しいeditorで最新sourceを読み直す。preview後の変更はcurrent stale-source rejectionで拒否する。

reader compatibilityは別の問いである。h-kernel形式の`reverses`を含むsourceへcutover後もBQN readerを向ける場合、BQN側のJournal admission adaptationが必要になる。writer切替とreader維持を一つの暗黙条件へ混ぜない。

## 4. Component boundary

```text
h-kernel-editor -> h-kernel
h-kernel-editor -> h-kernel-household
editor-app      -> h-kernel-editor
editor-tui-app  -> h-kernel-editor

the following are forbidden:
h-kernel            -> h-kernel-editor
h-kernel-household  -> h-kernel-editor
Report              -> h-kernel-editor
tools/hk            -> domain implementation
```

Editorは次を再実装しない。

- Account identityとclassification
- exact Quantity、Commodity、Balance
- Transaction balance
- Actual / Plan / Budget / Issue admission
- Report calculation

Editor固有の責任は次である。

- user/application edit intent
- candidate fragmentとsource placement
- complete-source preview
- stale checkとsafe publication
- confirmationとoperator-facing outcome

## 5. Daily-use cutover target

日常利用を`bqn-ledger`から`h-kernel`へ切り替える条件は、BQN editorの全機能を移植することではない。

必要な二本柱は現在mainに存在する。

1. 日常的に必要なwrite operationをpreview、strict admission、stale rejection付きで実行するHaskell editor
2. report、edit、check、helpを既存ownerへ委譲する一つのcommand hub

ただし、存在することとcanonical operationで安全に使えることは別である。writer authorityはまだ移動していない。

## 6. NEXT: daily-use non-canonical rehearsal gate

次の有限sliceは、明示したprivate non-canonical copyを使うdaily-use rehearsal contractとevidenceである。

有限な問い:

> `tools/hk`から日常的に必要なreportとeditor operationを一続きに使い、canonical sourceへ触れずに、preview、strict admission、stale rejection、backup、publication、post-admission、failure outcomeを確認できるか。

### Scope

- operatorがcanonical directoryとrehearsal copyを明示する
- 両directoryが別物であり、public checkout外であることを確認する
- write targetにはrehearsal copyだけを渡す
- source本文、Account、date、Quantity、Commodity、identity、path、hashをpublic outputへ出さない
- daily operation setを、現在本当に必要なoperationへ限定して記録する
- command hubのreport / edit / help経路を確認する
- safe writerのsuccessと少なくとも一つのstaleまたはrecoverable failureを確認する
- rehearsal前後でcanonical sourceがuntouchedであることをlocalに確認する

### Non-goals

- canonical writer cutover
- private sourceのpublic upload
- source migration
- BQN reader adaptation
- Plan editの新規実装
- full-screen command hub
- shared lock
- dual-editor alternating write
- historical reversal cleanup

rehearsal evidenceが閉じた後、作者の明示承認を受ける別PRでwriter authorityと日常入口を切り替える。

## 7. Remaining cutover decisions

canonical cutover前に、少なくとも次を明示する。

- 日常operation setと、cutover後にBQNへ戻る場合の扱い
- h-kernelが読むsource directoryの固定方法
- BQN reader/reportをcanonical sourceへ向け続けるか
- rollback時の唯一writer
- restore失敗時のoperator stop procedure
- cutover開始時に未完了operationがないこと
- 作者による明示承認

source topologyと10 gateの正規ownerは[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)である。

## 8. 関連文書

- [`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md): private sourceとwriter authority
- [`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md): reversal contract
- [`EDITOR_CUTOVER_READINESS_AUDIT_001.md`](EDITOR_CUTOVER_READINESS_AUDIT_001.md): earlier readiness evidence snapshot
- [`EDITOR_OPERATION_PARITY_INVENTORY_001.md`](EDITOR_OPERATION_PARITY_INVENTORY_001.md): operation inventory evidence
- [`ACTUAL_EDITOR_SEMANTIC_COMPARISON_001.md`](ACTUAL_EDITOR_SEMANTIC_COMPARISON_001.md): Actual semantic comparison evidence
- [`ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md`](ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md): synthetic TUI evidence
