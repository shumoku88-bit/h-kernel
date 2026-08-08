# h-kernel Editor 開発設計面

ステータス: アクティブな正規開発設計面  
Owner: h-kernel editor  
Canonical: yes  
更新日: 2026-08-08  
更新条件: editorのmain能力、daily-use入口、writer authority、次のcoherent editor chapterが変わるとき

## 1. この文書の役割

この文書は、`h-kernel` editorの現在能力、component境界、write effect、daily-use入口、次に完成させるcoherent editor chapterを所有する。

過去のE番号、branch、commit、完了PRの履歴はGitが所有する。この文書には、現在mainで使えるもの、まだ使えないもの、次に完成させるdomain capabilityまたはownership chapterだけを置く。

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
    complete source admission
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

一般multi-posting inputも、Brick固有の文字列文法や独自balance判定を持たせない。各postingはsigned quantityを持つ`ActualEditIntent`へ収束し、Account identity、Commodity resolution、Transaction balance、complete-source admissionは既存ownerへ戻す。

### 2.3 Preview, admission and safe writer

すべてのwrite candidateは、source mutation前にpreviewされる。

```text
explicit source path
  + typed intent
  -> pure candidate fragment
  -> candidate complete source
  -> stable complete-source admission
  -> preview
  -> explicit publication action
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

UI-independentな`ActualAddState`はcomplete private sourceを保持しない。Brick delivery contextは現在、previewとsafe writerのexpected-old-bytes境界を接続するため、読み込んだsource bytesを保持している。このplacementを変更する場合は、UI cleanupへ混ぜず、writer correctness / ownershipという別のsemantic rollback boundaryとして扱う。

### 2.4 Actual workspace TUI

Brick TUIのhomeはpersistent Actual workspaceである。

現在mainの日常Actual pathは次である。

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

このpathはcorrectnessを満たすが、日常記帳としてpreviewとconfirmationが重複し、操作距離が長い。daily-use completion chapterでは、validated candidateを一度だけ人間へ提示し、その画面から明示的にpublicationできる導線を優先する。安全性はscreen数ではなくtyped intent、complete-source admission、stale rejection、safe writerで担保する。

Brickはpane、focus、cursor、key mapping、widget、rendering、terminal eventを所有する。Account filterの意味、Actual addのinteraction transition、candidate preparation、safe writer semanticsは共有ownerへ委譲する。

Actual add成功後はfresh sourceを読み直してworkspaceへ戻り、新しいtransactionを表示する。成功を確認するためだけのdead-end result screenは作らない。失敗時はstale、restore済みfailure、未復旧failure、filesystem failureを有限なoutcomeとして表示する。

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

### 2.7 Plan complete and advance

Plans workspaceは、open Planを選び、Actualへ実績化し、必要ならsuccessor Planを同じcoherent operationで補充できる。

- Actual dateとnominal Plan dateを分離する
- Actual amount overrideはsuccessor amountへ暗黙伝播しない
- monthly recurrenceのnext dateはoriginal nominal Plan dateから提案する
- once recurrenceはsuccessorなしを標準にする
- cycle / unspecified recurrenceはnext nominal dateを明示入力する
- Actual completionはexisting plan-idを再利用し、successorはfresh PlanIdを持つ
- ActualとPlanの双方をcomplete candidateとして検証してからpublishする

このsemantic contractはdaily-use completion chapterで変更しない。対象は操作距離、表示、戻り先などdelivery ergonomicsである。

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

## 5. NEXT: daily-use TUI completion chapter

次のcoherent editor chapterは、日々の家計運用で最も頻度の高い操作を、command hubへ戻らずHousehold TUIだけで短く完了できる状態にすることである。

日常利用のacceptance criterionは次である。

> `tools/hk`を起動し、通常の記帳、必要なmulti-posting記帳、予定支出の実績化と次回予定の補充、主要reportの閲覧まで、CLI commandへ逃げずに到達できる。

優先順位は固定する。

1. ordinary daily Actual entry
2. multi-posting Actual entry
3. Plan completion and successor replenishment
4. direct Report selection

Account maintenance、Budget maintenance、Issue maintenance、Settings編集などの低頻度operationは、このdaily-use acceptance criterionを満たした後に扱う。

### 5.1 Ergonomic laws

- common pathを最短にする
- uncommon optionは失わず、通常操作の途中へ常設しない
- command一覧からverbを選ぶのではなく、workspaceで対象を見て必要なoperationへ入る
- same validated candidateをPreviewとConfirmationの二画面で重複表示しない
- source mutation前にcandidateは必ず人間へ提示する
- publication actionは明示的なkeyで行う
- successful writeはfresh Household reload後、意味のあるworkspaceへ戻す
- failureだけは十分な情報を残し、続行不能なら明示して止める
- Brick toolkit stateとdomain interaction stateの重複は、操作距離を減らすために必要な範囲で整理する
- generic command frameworkやgeneric form frameworkは導入しない

### 5.2 Ordinary Actual

ordinary daily Actualは最頻operationなので、amountをfirst focusとし、Todayとcanonical Account defaultを積極的に既定値として使う。

目標flowは次である。

```text
Actual workspace
  -> [a]
  -> amount / description / typed Account selection
  -> validated preview
  -> explicit publish
  -> fresh Actual workspace
```

Todayは入力不要、Yesterdayはone-key shortcut、other dateは明示的に開く。Account候補はtyped AccountRegistryから作り、recent-first表示とcase-insensitive searchを使う。

### 5.3 Multi-posting Actual

multi-postingはordinary Actualとは別の会計モデルではない。どちらも同じ`ActualEditIntent`と`TransactionBlock` admissionへ収束する。

```text
ordinary two-posting input --+
                             +-> ActualEditIntent -> TransactionBlock admission
multi posting-row input -----+
```

multi pathでは各postingがAccount identityとsigned quantityを持つ。Commodityを省略できるのは、そのAccountのcanonical defaultが一意に得られる場合だけである。

Brick deliveryは次を担当する。

- posting rowの選択
- typed Account picker
- signed amount input
- posting row追加
- 3行を下回らない範囲でposting row削除
- Today / Yesterday / other date shortcut
- validated previewへの遷移

Brickはtotal=0判定、Commodity accounting rule、Account declaration ruleを再実装しない。unbalanced transactionは既存`TransactionBlock` admissionが拒否する。

### 5.4 Plan completion and replenishment

現在のComplete & Advance semantic contractを保ち、Planを選んだ地点から実績化と次回補充へ短く到達できることを優先する。

通常ケースでは予定金額をActual amountのdefault、monthly proposalをsuccessor dateのdefaultとし、変更がないfieldへ余分な入力を要求しない。successor不要の場合も明示的かつ短く選べること。

### 5.5 Reports

Reports sectionは`r`を繰り返して順番に巡回するだけのsurfaceから、named reportを直接選択できるsurfaceへ変える。

少なくともdaily-useで次へ直接到達できることを優先する。

- Account balances / Balance Sheet
- Recent Actual
- Planned Transactions
- Current Cycle / Cycle Comparison
- Daily Flow / Monthly Accounts
- Daily Target
- Envelope & Backing

Report calculationやrendering semanticsをTUIへ複製しない。typed report ownerを選択してrenderするだけにする。

### 5.6 State ownership cleanup

Brick `UIState`とUI-independent interaction stateの重複整理は独立目的ではなく、上記daily-use flowを短く明瞭にするための手段として行う。

Form、Brick List、cursor、focus、viewportはtoolkit stateとして残してよい。interaction meaning、candidate readiness、publication readinessをBrickとshared ownerで二重所有している場合だけ整理する。

### Non-goals

- safe writer contractの変更
- expected old bytes / complete source retentionの移動
- writer authority変更
- source format migration
- reversal identity policy変更
- Plan recurrence semantics変更
- Haskeline implementation追加
- generic UI framework導入
- directoryの見た目だけの再配置
- Spike卒業
- private canonical sourceの変更

これらはfileやmoduleが違うからではなく、rollback条件とdomain meaningが異なるためchapter境界の外に置く。

## 6. Remaining decisions after daily-use completion

- Brick delivery contextのsource-byte retentionとsafe writer ownershipのseparate ownership chapter
- Actual reverse target selectorとidentity input experience
- Plan edit interaction
- Account maintenance interaction
- Budget maintenance interaction
- Issue maintenance interaction
- Settings maintenance interaction
- Haskelineまたは他adapterを実際に追加する必要が生じた時のdelivery構成
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
