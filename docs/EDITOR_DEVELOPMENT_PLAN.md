# h-kernel Editor current policy and roadmap

ステータス: active  
Owner: Editor interaction、safe publication、current practical priorities

## 目的

Editorは、admitted Household stateで見えているobjectから自然な操作へ進み、canonical sourceを壊さず日常の家計操作を完了させる。

この文書はEditor固有のinteraction law、safe-publication law、まだ残っている実用上のpriorityだけを所有する。Canonical source shape / reader topologyは[`HOUSEHOLD_CANONICAL_SOURCE.md`](HOUSEHOLD_CANONICAL_SOURCE.md)、writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)、component boundaryは[`ARCHITECTURE.md`](ARCHITECTURE.md)、delivery portabilityは[`PLATFORM_NEUTRAL_APPLICATION_POLICY.md`](PLATFORM_NEUTRAL_APPLICATION_POLICY.md)が所有する。

実装済みcommand、workspace field、key binding、module inventoryをこの文書へ転記しない。current implementationとtestを正本にする。

## Interaction law

TUIはcommand一覧の移植先ではない。現在見えているHousehold objectとtyped identityを保持し、そのobjectへ自然なoperationへ進む。

```text
Actual -> record / reverse
Plan   -> complete / advance / edit
Issue  -> maintain / realize as explicit Actual evidence
Budget -> movement
Account -> add
```

- canonical Account名、PlanId、Actual identity、IssueIdを人間へ暗記させることを日常pathの前提にしない
- 表示Text、list index、source lineからdurable identityを再構築しない
- ordinary transactionとmulti-posting transactionを別のaccounting modelに分けない
- confirmationはconsequenceを理解する必要があるoperationに使い、同じcandidateを儀式的に何度も確認しない
- operation成功後はfresh Household observationへ戻り、古いworkspace stateをauthorityにしない
- keyboard pathを保ち、mouseやpickerは同じvisible objectへの補助入口にする

具体的なportable key contractは`PLATFORM_NEUTRAL_APPLICATION_POLICY.md`、画面遷移とfield shapeはTUI implementation / testが所有する。

## Home boundary

Homeはadmitted Household stateから作るcalendar-first projectionであり、feature menuや新しいcanonical ownerではない。

Home専用source reload、cycle計算、canonical model、未計測cacheを作らない。選択日へ対応するadmitted Actual / Plan / Issue / cycle evidenceを表示してよいが、`Actual none recorded`から「記帳漏れ」など生活上の意味を推測しない。

marker、glyph、focus、selected-day paneなどcurrent presentation shapeはTUI implementationとtestが所有する。見た目やnavigationは実運用で繰り返し現れる摩擦から改善し、dashboardを埋めるために新しいdomain meaningを作らない。

## Candidate and publication law

基本形は次である。

```text
user intent
  -> typed identity / input
  -> pure candidate preparation
  -> complete-source admission
  -> preview when consequence warrants it
  -> named writer publication
  -> complete Household post-admission
  -> fresh workspace
```

single-source publicationは、expected bytesに対するstale rejection、complete candidate admission、backup、sibling staged candidate、immediate pre-publication stale recheck、atomic publication、post-admissionを順に守る。失敗時のrestoreはtargetがjust-published candidateから変化していない場合だけ行い、後から入った別writerの変更を上書きしない。

cross-file operationではfilesystem全体のatomicityを装わない。publication前に必要sourceのexpected stateとcandidateを揃え、whole-Household post-admissionを通し、失敗時は対象sourceごとのchecked restoreを行う。

UI stateへcomplete private source、backup、writer authorityを持ち込まず、CLI/TUIがpublication lawを複製しない。write capabilityとcanonical writer authorityは別であり、authority変更は`WRITER_AUTHORITY.md`のcutover gateに従う。

## Issue relation current boundary

Issue relationのtyped coreと最初の実用workflowが存在する。

- `IssueRelationEvent`は独自のdurable event identityを持つ
- Plan targetとdurable Actual targetをtyped constructorで区別する
- `concerns-plan`、`planned-as`、`planning-withdrawn`、`realized-as`、`funded-by`の意味を区別する
- cross-source target existenceは`admitIssueRelationReferences`がfail closedで検証する
- `HKernel.Household.Issue.Relation.TSV`がsix-coordinate source-local syntaxを所有する
- `HKernel.Editor.IssueRealize`が、open Issueを新しいsource-durable Actualへ明示的にrealizeするcandidateと三source publicationを所有する
- 新Actualには最初からexplicit `event-id`を付け、relationはそのexact identityだけを`IssueRealizedAs` targetにする
- relation recorded date、Actual date、Issue close dateは別座標であり、current configurationや互いの値から推論しない
- Actual / relation / Issueのcomplete candidateをpublication前にadmitし、stale / post-admission failureではchecked recoveryを行う
- relation sourceがまだ存在しない場合は、最初のsuccessful realizationだけがheader付きsourceを作る

`issue-relations.tsv` は同じHousehold root配下のexplicit provenance sidecar coordinateとして解決するが、current eight-source `HouseholdState` / ordinary `HouseholdWriteSnapshot`へはまだ昇格していない。この境界は[`HOUSEHOLD_CANONICAL_SOURCE.md`](HOUSEHOLD_CANONICAL_SOURCE.md)が所有する。

最初のdeliveryはsource pathを人間へ分散させないHousehold-root based CLIからこのownerを呼ぶ。TUIへ接続するときは、existing Record flowが持つtyped `ActualEditIntent`を最後まで保持して同じownerへ渡す。rendered preview Text、amount、date、memo、Account resemblanceからActual intentやrelation targetを再構築してはならない。

Budget movementは現在stable movement identityを持たないため、date / memo / amount / row positionの近似一致でrelation targetを捏造しない。relation eventが存在することとIssue lifecycleは別であり、universal relation graphやgeneral event frameworkへ拡張しない。

## CLI boundary

CLIにexplicit source pathやsource-shaped grammarが残ること自体を負債とみなさない。scripting、低水準operation、compatibility、writer authority上の役割があり得る。

Householdを跨ぐoperationは、individual source pathsを利用者へ列挙させず一つの`HouseholdRoot`から必要coordinateを解決してよい。これはgeneric repository/session abstractionではなく、そのoperationが必要とする明示的なsource topologyである。

CLIを整理する場合はcurrent usageの具体的摩擦から始め、見た目を揃えるためだけにsource ownership、source format、writer authorityを変更しない。`tools/hk`は既存ownerへのrouterであり、会計ruleを所有しない。

## Current practical priorities

優先順位は実際のHousehold利用で観察した頻度と摩擦から決める。

1. Home / TUIを日常利用し、視認性、repeated typing、不要なmodal traversal、canonical-string recallを減らす
2. TUIのselected Issue -> Realize pathではexisting Recordのtyped intentを保持して`IssueRealize` ownerへ渡し、rendered Textから意味を再構築しない
3. Record、Plan completion / successor、Budget movement、Issue maintenanceをvisible objectから短く完了できる状態を保つ
4. Issue relationの次のmeaningは具体的なHousehold workflowとdurable target identityが揃った場合だけ追加する
5. Editor CLIは具体的なoperational frictionが確認された場合だけ整理する
6. performanceは実測で問題になったruntime pathだけ改善する

このroadmapの列挙を実装済み状態のinventoryとして使わない。変更を始める前にcurrent main、owner module、testを確認する。

## Non-goals

- generic command / form framework
- generic repository / session abstraction
- universal relation graph / event store
- Home専用canonical model
- dashboardを埋めるためのdomain追加
- future GUI / HTTP / mobileを想像した先回り抽象
- LOC削減やHaskell機能導入そのものを目的にしたrefactor

検証手順は[`REPOSITORY_POLICY.md`](REPOSITORY_POLICY.md)とCIを正本とし、この文書へcommand snapshotを複製しない。
