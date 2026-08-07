# h-kernel Editor 開発設計面

ステータス: アクティブな正規開発設計面  
Owner: h-kernel editor  
Canonical: yes  
更新日: 2026-08-07  
更新条件: editorのmain能力、daily-use入口、writer authority、次の有限sliceが変わるとき

## 1. この文書の役割

この文書は、`h-kernel` editorの現在能力、component境界、write effect、daily-use入口、次に検証する一つの有限sliceを所有する。

過去のE番号、branch、commit、完了PRの履歴はGitが所有する。この文書には、現在mainで使えるもの、まだ使えないもの、次に観察する境界だけを置く。

## 2. CURRENT

```text
canonical source                 separate private data repository
actual.journal canonical writer  h-kernel editor
actual.journal readers           bqn-ledger and h-kernel
other source writer authority    unchanged by Actual cutover
h-kernel role                    report engine + explicit editor + workspace-first daily entrypoint
Actual writer cutover            approved 2026-08-06
```

現在のEditorは、共有operationとdelivery adapterを分ける。

```text
h-kernel-editor
  source: editor-src/
  owns:
    typed edit intent
    candidate preparation and source placement
    complete-source admission
    safe writer result
    typed Actual workspace projection
    UI-independent Actual add interaction

h-kernel-editor-cli
  source: editor-app/
  owns:
    argv / preview / explicit --commit / exit status / effect delivery

h-kernel-editor-tui
  source: editor-tui-app/
  owns:
    Brick workspace / pane / focus / cursor / key binding / rendering / effect delivery

tools/hk
  owns:
    workspace-first daily routing and explicit command routing only
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

Plan editはcurrent CLI operationではない。BQN editorに存在したsurfaceを網羅すること自体は目標にしない。

`actual.journal`へwriteするoperationは、cutover後の唯一writerとして`h-kernel` editorを使う。Budget movement、Issue、Plan sourceそのもののwriter authorityは、このActual cutoverから推測して移さない。

### 2.2 Shared Editor ownership

Actual addの意味は一つのTUI moduleへ閉じ込めない。

```text
HKernel.Editor.ActualAppend
  -> free-form input admission
  -> typed edit intent
  -> candidate preparation
  -> preview result
  -> write outcome classification

HKernel.Editor.Interaction.ActualAdd
  -> selection target
  -> interaction mode
  -> interaction state
  -> interaction action
  -> pure transition

HKernel.Editor.ActualWorkspace
  -> typed Account selectionからActual transaction projection
```

`HKernel.Editor.Interaction.ActualAdd`はBrick、Haskeline、cursor、widget、filesystem effectを所有しない。ActualAppend所有の型や関数を再exportする互換棚も持たない。

Account pickerで選んだidentityは`Account`のままInteractionへ渡し、free-form `ActualAddInput`へ反映する地点でだけ`accountName`へ落とす。表示TextをAccount identityとして扱わない。

### 2.3 Preview, admission and safe writer

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

CLIやTUIはこの処理を複製しない。

- preview後にsourceが変わっていればwriteしない
- domain admissionが失敗した場合はsourceへ触れない
- publish後のadmission failureでは通常運用を継続しない
- backup、temporary file、recovery artifact、private sourceをGitへ入れない
- focused testとpublic CIはsynthetic sourceだけを使う

UI-independentな`ActualAddState`はcomplete private sourceを保持しない。Brick delivery contextは現在、previewとsafe writerのexpected-old-bytes境界を接続するため、読み込んだsource bytesを保持している。このplacementを変更する場合は、UI cleanupではなくwriter correctness / ownershipの別sliceとして扱う。

### 2.4 Actual workspace TUI

Brick TUIのhomeはpersistent Actual workspaceである。

```text
Accounts pane
  -> typed Account selection
  -> Transactions pane projection
  -> selected Transaction detail

[a]
  -> Actual add input
  -> Account picker
  -> preview
  -> explicit confirmation
  -> existing safe writer
  -> fresh source reload
  -> workspace
```

Brickはpane、focus、cursor、key mapping、widget、rendering、terminal eventを所有する。Account filterの意味、Actual addのinteraction transition、candidate preparation、safe writer semanticsは共有ownerへ委譲する。

Actual add成功後はfresh sourceを読み直してworkspaceへ戻り、新しいtransactionを表示する。失敗時はstale、restore済みfailure、未復旧failure、filesystem failureを有限なoutcomeとして表示する。

### 2.5 Daily workspace entrypoint

日常入口は`tools/hk`である。TTYで引数なし実行した場合、shell operation menuを経由せずActual workspaceへ直接入る。

```text
tools/hk
  no args         -> Actual workspace
  report          -> report launcher
  actual-add      -> Actual workspace with explicit Journal path
  actual-multi    -> editor CLI append
  actual-reverse  -> editor CLI reverse
  account         -> editor CLI account
  plan            -> editor CLI plan
  budget          -> editor CLI budget
  issue           -> editor CLI issue
  edit            -> editor CLI direct route
  check           -> build / test / repository audit
  help            -> usage
```

`--base DIR`、`HKERNEL_LEDGER_DATA_DIR`、`ledger-data.local`はprivate ledger directoryを解決するためのdelivery concernである。`tools/hk`は会計計算、candidate admission、source mutation ruleを再実装しない。

shell `prompt_choice`、gum / fzf selector、numeric operation menuはdaily navigation modelから削除済みである。

### 2.6 Actual reversal

Actual reverseは元Transactionを変更せず、新しいTransactionをappendする。

- postingsを順序とCommodityを保ってexactに反転する
- reversalは新しいdurable `event-id`を持つ
- `reverses` metadataでtargetを明示する
- unknown target、self-reference、duplicate direct reversalを拒否する
- reverse-of-reverseは新しいexplicit edgeとして許可する

日常routeは`tools/hk actual-reverse`から既存Editor CLIへ委譲する。専用selectorまたはreverse専用TUIはまだ存在しない。詳細は[`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md)が所有する。

## 3. Single-user writer law

このprojectのcanonical editorは一人のoperatorが順番に使う。

cross-process shared lock、二つのeditorによるalternating canonical write、lock contention testは要件にしない。

```text
canonical actual.journal writer = h-kernel editor
bqn-ledger actual write          = prohibited by operation
other source writer authority    = unchanged by this cutover
```

`bqn-ledger`をreaderまたはReport engineとしてcanonical sourceへ向け続けることはできる。ただし、canonical `actual.journal`を変更するcommandへは使わない。

writerを切り替えた後は、旧editorのoperationを終了し、新しいeditorでlatest sourceを読み直す。preview後の変更はcurrent stale-source rejectionで拒否する。

reader compatibilityは別の問いである。h-kernel形式の`reverses`を含むsourceへBQN readerを向ける場合、BQN側のJournal admission adaptationが必要になり得る。writer切替とreader維持を一つの暗黙条件へ混ぜない。

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

EditorはAccount identity、Money、Transaction balance、Actual / Plan / Budget / Issue admission、Report calculationを再実装しない。

Editor固有の責任は、user/application edit intent、candidate fragmentとsource placement、complete-source preview、stale checkとsafe publication、UI-independent interaction contractである。delivery adapterはterminal/process/file effectを接続する。

## 5. NEXT: Actual workspace state ownership audit

次の有限sliceは、Brick workspaceが持つscreen stateとUI-independent `ActualAddState`の関係を観察することである。

有限な問い:

> Brickの`UIState`にあるInput / Account selection / Preview / Confirmationのscreen caseと、`ActualAddMode`のinteraction caseは、同じ意味を二重所有しているか。もし重複しているなら、Brick toolkit固有のstateを残したまま、どこまで`ActualAddState`をcanonical interaction stateとして使えるか。

### Scope

- Brick `UIState`と`ActualAddMode`のcase対応を全列挙する
- Form、Brick List、cursor、focus、renderingなどtoolkit固有stateを区別する
- interaction meaning、derived screen state、effect-delivery stateを区別する
- duplicated state transitionとmanual synchronizationを特定する
- Haskelineなど別adapterが再利用するべき最小state/action contractを確認する
- 削除できるcase、branch、conversionが明確な場合だけ次のfinite implementation sliceを切る

### Non-goals

- safe writer contractの変更
- expected old bytes / complete source retentionの移動
- writer authority変更
- source format migration
- reversal identity policy変更
- Haskeline implementation追加
- generic UI framework導入
- directoryの見た目だけの再配置
- Spike卒業

## 6. Remaining decisions

- Brick screen stateとUI-independent interaction stateの重複整理
- Brick delivery contextのsource-byte retentionとsafe writer ownershipの別audit
- Haskelineまたは他adapterを実際に追加する必要が生じた時のdelivery構成
- Actual multi-postingの日常interaction
- Actual reverse target selectorとidentity input experience
- Plan source writer authority
- Budget movement source writer authority
- Issue source writer authority
- Account declarationを将来`accounts.journal`へ分離する時期
- BQN readerがHaskell-native reversal provenanceを読む必要があるか
- private source topology migration

source topologyとsource別authorityの正規ownerは[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)である。

## 7. 関連文書

- [`ARCHITECTURE.md`](ARCHITECTURE.md): component、dependency、effect boundary
- [`HASKELL_NATIVE_CODE_POLICY.md`](HASKELL_NATIVE_CODE_POLICY.md): Haskellとdomain structureの対応
- [`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md): private sourceとsource別writer authority
- [`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md): Actual writer cutover、activation、stop、rollback
- [`ACTUAL_REVERSE_PROVENANCE_DECISION_001.md`](ACTUAL_REVERSE_PROVENANCE_DECISION_001.md): reversal contract
- [`EDITOR_CORRECTNESS_REVIEW.md`](EDITOR_CORRECTNESS_REVIEW.md): correctness recoveryの完了記録
