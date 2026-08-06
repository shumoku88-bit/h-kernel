# h-kernel Editor 開発設計面

ステータス: アクティブな正規開発設計面  
Owner: h-kernel editor  
Canonical: yes  
更新日: 2026-08-06  
更新条件: editorのmain能力、daily-use入口、writer authority、cutover gate、次の有限sliceが変わるとき

## 1. この文書の役割

この文書は、`h-kernel` editorの現在能力、component境界、write effect、writer cutover後の次の一歩を所有する。

過去のE番号、branch、commit、完了PRの履歴はGitが所有する。この文書には、現在mainで使えるもの、まだ使えないもの、次に検証する一つの有限sliceだけを置く。

## 2. CURRENT

```text
canonical source                 separate private data repository
actual.journal canonical writer  h-kernel editor
actual.journal readers           bqn-ledger and h-kernel
other source writer authority    unchanged by Actual cutover
h-kernel role                    report engine + explicit editor + daily command hub
Actual writer cutover            approved 2026-08-06
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
  owns: report / actual-add / edit / check / help routing only
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

`actual.journal`へwriteするoperationは、cutover後の唯一writerとして`h-kernel` editorを使う。Budget movement、Issue、Plan sourceそのもののwriter authorityはこのcutoverから推測して移さない。

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

ordinary canonical Actual addの日常入口は次である。

```sh
./tools/hk actual-add /absolute/path/to/actual.journal
```

### 2.6 Daily command hub

`tools/hk`は日常入口としてmainへmergeされている。

```text
tools/hk
  -> report
  -> actual-add
  -> edit
  -> check
  -> help
```

- 引数なしは既存report launcherへ委譲する
- `report`は既存report entrypointへ引数を渡す
- `actual-add`は一つのexplicit Journal pathを既存Actual add TUIへ渡す
- `edit`は`h-kernel-editor-cli`へ引数を渡す
- `check`はrepository標準build、test、ownership auditを呼ぶ
- command hub自身はsourceを読まず、書かず、会計計算をしない

## 3. Single-user writer law

このprojectのcanonical editorは一人のoperatorが順番に使う。

cross-process shared lock、二つのeditorによるalternating canonical write、lock contention testは要件にしない。

```text
canonical actual.journal writer = h-kernel editor
bqn-ledger actual write          = prohibited by operation
other source writer authority    = unchanged by this cutover
```

`bqn-ledger`をreaderまたはReport engineとしてcanonical sourceへ向け続けることはできる。ただし、canonical `actual.journal`を変更するcommandへは使わない。

writerを切り替えた後は、旧editorのoperationを終了し、新しいeditorで最新sourceを読み直す。preview後の変更はcurrent stale-source rejectionで拒否する。

reader compatibilityは別の問いである。h-kernel形式の`reverses`を含むsourceへBQN readerを向ける場合、BQN側のJournal admission adaptationが必要になる。writer切替とreader維持を一つの暗黙条件へ混ぜない。

Actual-specific activation、stop、rollbackは[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

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

## 5. Actual cutover evidence

cutover判断は、BQN editorの全機能移植ではなく、`actual.journal`の必要operationとsingle-writer boundaryに基づく。

現在のevidenceは次である。

- Actual ordinary append、multi-posting、reverse、Account declaration、Plan finishのnamed operation
- mutation前previewとstrict complete-source admission
- stale rejection
- backup、atomic publication、post-admission、restore-capable failure
- synthetic sourceでのsuccess、stale、restore test
- BQN/Haskell Actual candidateのsemantic comparison
- private canonical sourceの明示的non-canonical copyでのpreview、commit、post-admission rehearsal
- canonical source、repository file、writer authorityがrehearsal中に不変であったというsanitized operator evidence
- 作者による2026-08-06の明示承認

cutover contractは[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

## 6. NEXT: Actual daily-use observation period

次の有限sliceは、新しい機能の追加ではなく、Actual-only cutover後の日常運用を観察することである。

有限な問い:

> canonical `actual.journal`のordinary addを`tools/hk actual-add`から行い、single-writer law、preview、confirmation、publication、post-admission、Report readbackを日常の小さなoperationとして維持できるか。

### Scope

- ordinary Actual addを最初の日常operationとする
- write前にlatest sourceを読み、TUIでpreviewする
- confirmation後だけpublicationする
- write success後にReportまたはstrict admissionでreadbackする
- `bqn-ledger` writerをcanonical `actual.journal`へ向けない
- failure時は次のwriteを止め、cutover contractのstop procedureへ戻る
- private valueをpublic Issue、PR、CI、fixtureへ出さない
- operation outcomeだけをsanitizedに記録する

### Non-goals

- source format migration
- Budget、Issue、Plan source writer cutover
- bqn-ledger reader removal
- Plan editの新規実装
- shared lock
- dual-editor alternating write
- historical reversal cleanup
- UIの大型化

観察期間でActual addの不足が見つかった場合も、他sourceのcutoverや無関係なeditor featureを同じsliceへ混ぜない。

## 7. Remaining decisions after Actual cutover

Actual-only cutover後にも、次は別の明示sliceとして残る。

- Plan source writer authority
- Budget movement source writer authority
- Issue source writer authority
- Account declarationを将来`accounts.journal`へ分離する時期
- BQN readerがHaskell-native reversal provenanceを読む必要があるか
- rollback時にreader compatibilityをどこまで維持するか
- private source topology migration

source topologyとsource別authorityの正規ownerは[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)である。

## 8. 関連文書

- [`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md): private sourceとsource別writer authority
- [`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md): Actual writer cutover、activation、stop、rollback
- [`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md): reversal contract
- [`EDITOR_CUTOVER_READINESS_AUDIT_001.md`](EDITOR_CUTOVER_READINESS_AUDIT_001.md): earlier readiness evidence snapshot
- [`EDITOR_OPERATION_PARITY_INVENTORY_001.md`](EDITOR_OPERATION_PARITY_INVENTORY_001.md): operation inventory evidence
- [`ACTUAL_EDITOR_SEMANTIC_COMPARISON_001.md`](ACTUAL_EDITOR_SEMANTIC_COMPARISON_001.md): Actual semantic comparison evidence
- [`ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md`](ACTUAL_ADD_TUI_REHEARSAL_EVIDENCE_001.md): synthetic TUI evidence
