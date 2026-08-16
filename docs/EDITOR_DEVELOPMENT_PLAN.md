# h-kernel Editor 開発方針

ステータス: active  
Owner: h-kernel editor / Household application  
更新日: 2026-08-13

## 目的

Editorの目的は、canonical Household sourceを壊さず、日常の家計操作を少ない迷いと少ない手順で完了できるようにすることにある。

設計判断は次で評価する。

- 実際の家計操作が完了できるか
- 入力、選択、確認の負担が妥当か
- exact arithmetic、identity、provenanceを失わないか
- canonical sourceとwriter authorityを守るか
- invalid/stale candidateをfail closedできるか
- operation後にfresh Household stateへ戻れるか
- domain ruleをCLI/TUIへ重複実装していないか
- 新しい抽象やstateが、実在する問題より大きくなっていないか

特定の言語機能、architecture pattern、LOC、抽象度を達成目標にしない。

## Canonical Household boundary

shared canonical Household rootは次の8 sourceである。

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

sourceへUI stateやdelivery-specific representationを持ち込まない。source semanticsへ未対応のreader/writerはsilent ignoreせずfail closedする。

write capabilityとcanonical writer authorityは別である。authority変更はsource migration/cutover contractで明示する。

## Daily interaction target

TUIはcommand一覧を移植する場所ではない。現在見えているHousehold objectから、そのobjectへ自然なoperationへ進める。

```text
Actual selected -> Reverse
Plan selected   -> Complete / Advance / Edit
Issue selected  -> Resolve / Drop
Budget          -> Movement
Accounts        -> Add Account
```

Recordはordinary transactionとmulti-posting transactionを別世界にしない。必要なposting数へ自然に拡張できる一つの記帳体験を目指す。

Issues workspaceはattention surfaceとしてOpenだけを既定表示する。ResolvedとDroppedはcanonical sourceから削除せず、TUIの明示的なOpen / Closed / All表示で履歴を確認できるようにする。表示選択はTUI stateであり、Issue lifecycleや`issues.tsv`を変更しない。

日常操作では、canonical Account名、PlanId、event-idなどを人間へ暗記させない。workspaceがtyped identityを保持し、表示Textからidentityを再構築しない。

keyboard operationは完全に保ち、mouseは同じvisible objectへの短い入口として使える。click-only mutationは作らない。

## Household Home

Homeはcalendar-firstのHousehold-state projectionであり、feature menu、dashboard、新しいcanonical ownerではない。

現在の基本動作は次である。

```text
起動
  -> 今日を含む月間Calendarを見る
  -> 日を選ぶ
  -> その日のadmitted factsを見る
  -> 必要なら選択日からRecordする
```

Calendarの一文字markerは、同じHousehold observationから得た次の3つのattention factだけを表す。

- open outgoing payment Planのdue date
- open Issueのdue date
- current cycleのend day (`end-exclusive - 1 day`)

これらは独立した事実であり、優先順位で一つを勝たせない。1つだけ成立する日はその意味のmarkerを表示し、2つ以上が同日に成立する場合は`multiple-marker`を表示する。

Actualの存在はmarker帯域を消費しない。selected-day paneで、その日付に対応するActual transaction/postings、payment Plan、Issue due、cycle end dayの根拠を表示する。過去日は記録確認、未来日は予定や注意点の確認に使う。

`Actual none recorded`は観察された事実であり、記帳漏れという判断ではない。UIは記録がないことから生活上の事実を推測しない。

Calendarのmarkerはpresentationであり、glyphだけを設定できる。markerを生じさせるHousehold factや、複数factが重なったという意味を設定へ移さない。cell幅はterminal matrixを崩さない固定幅とする。

今日の表示、選択状態、markerは別の意味を持つ。現在地のcueをaccounting semanticsやattention severityと混同しない。

Homeは既にadmitされた`HouseholdState`とHousehold report surfaceを使う。Home専用canonical model、source reload、重複cycle計算、未計測のcacheを追加しない。

HomeとTUI全体の見た目・操作は、しばらく実際に使いながら少しずつ修正する。先に機能一覧やdashboard layoutを固定せず、繰り返し現れる摩擦と見えにくさから変更する。

## Issue relation

`HouseholdIssue`は家計上の検討・問題・判断対象であり、それ自体はActual fact、Plan commitment、Budget movementではない。Issueが後に別のobjectへつながった場合だけ、具体的なprovenance relationを表す。

現在のidentity上の前提:

- Issueはstable `IssueId`を持つ
- Planはdurable `PlanId`を持つ
- Actualは`ActualTransactionId`を持てるが、ordinary Actual transactionはidentity-freeでもよい
- `HouseholdBudgetMovement`には現在stable movement IDがない

最初に観察するrelationは`Issue -> Plan`とする。date、memo、amountの類似からrelationを推測しない。

将来の意味としては、例えば次を区別できるようにしたい。

```text
Issue -> Plan             予定化した
Issue -> Actual           実際の支払い・取引で対処した
Issue -> Budget movement  資金移動で対処した
```

ただし`Issue -> Actual`と`Issue -> Budget movement`は、対象を長期に一意に指せるidentity lawが成立してから設計する。source line番号やlist indexをdurable identityとして使わない。

relationが追加されたこととIssueが`Resolved` / `Dropped`になることは別である。relationは処理・判断の履歴を示し、lifecycle statusを自動決定しない。

universal relation graphやgeneral event frameworkを先に作らない。最初の実際のworkflowから必要なrelationだけを追加する。

## Candidate and publication boundary

基本形:

```text
user intent
  -> typed selected identity / input
  -> pure candidate preparation
  -> complete-source admission
  -> preview when consequence warrants it
  -> publication through the named writer owner
  -> complete Household post-admission
  -> fresh workspace
```

confirmationは危険なoperationを理解するために使う。同じcandidateを意味なく何度も確認させない。

## Writer law

single-source publicationは最低でも次を守る。

```text
expected bytes
  -> complete candidate admitted
  -> stale rejection
  -> backup
  -> sibling staged candidate
  -> immediate pre-publication stale recheck
  -> atomic publication
  -> post-admission
  -> success
     or checked restore-capable failure
```

rollbackはtargetが自分のjust-published candidateから変化していない場合だけ行う。後から入った別writerの変更を上書きしない。

cross-file operationではfilesystem全体のatomicityを装わない。publication前に必要sourceのexpected stateとcandidateを揃え、whole-Household post-admissionを通し、失敗時は各sourceをchecked restoreする。

## Delivery ownership

Domain/editor owner:

- accounting semantics
- identity / provenance
- candidate preparation
- admission
- publication law

CLI/TUI owner:

- argv / terminal event
- focus / cursor / widget
- free-form input
- visible selection
- preview / confirmation presentation
- named operationのeffect invocation
- user-facing outcome

UI都合でbalance law、Account classification、Plan recurrence、identity relation、source admissionを再実装しない。

## CLI application model

TUIはHousehold rootから一つのHousehold observationを扱う一方、CLIにはexplicit source pathやsource-shaped command grammarが残っている。

これは自動的に負債とはみなさない。compatibility、scripting、低水準operation、writer authority上の理由があり得る。

CLIを整理するときは、まずcurrent mainで次を観察する。

- canonical Household operationとして実際に使うcommand
- compatibility / low-level toolとして残すcommand
- `tools/hk`がroutingだけを担当しているか
- Household-root-oriented CLIが実際の操作や保守を簡単にするか
- source format retirementやwriter authority changeを混ぜていないか

CLIの見た目を揃えるためだけにsource ownershipを変更しない。

## Current practical priorities

優先順位はHouseholdを実際に使う頻度と不便さで決める。

1. Calendar-first HomeとTUI全体を実際に使い、繰り返し現れる視認性・操作摩擦を小さく直す
2. Record / Plan completion / successor replenishment / Budget / Issue maintenanceをvisible objectから短く完了できるようにする
3. repeated typing、canonical-string recall、不要なmodal traversalを減らす
4. 最初の具体的な`Issue -> Plan` workflowを観察し、必要なrelation meaningだけを設計する
5. `Issue -> Actual` / `Issue -> Budget movement`に必要なdurable identityを、実際のworkflowが要求した時点で検討する
6. Editor CLIのsource-oriented grammarは、current useを再観察して具体的な摩擦がある場合だけ整理する
7. 実測で問題があるruntime pathだけを性能改善する

新しい機能へ進む前に、current codeとremoteを確認する。この文書の列挙を実装済み状態の代わりに使わない。

## Non-goals

- generic command framework
- generic form DSL
- generic repository/session abstraction
- generic relation graph / universal event store
- Home専用canonical modelや先回りcache
- dashboardを埋めるための情報追加
- architecture diagramを満たすためのlayer追加
- future GUI/HTTP/mobileを想像した先回り抽象
- LOC削減だけを目的にしたrefactor
- Haskell機能を導入すること自体を目的にしたrefactor

## Completion evidence

変更ごとに必要な範囲で次を確認する。

```sh
cabal build all
cabal test all
cabal run repository-audit
```

Reportへ影響する場合:

```sh
./report-build
./report-verify --fixture
./report-verify --corpus
```

canonical sourceへ影響する場合はprivate dataを出力せず、current canonical Householdでadmission/publication contractを追加確認する。
