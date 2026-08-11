# h-kernel Editor 開発方針

ステータス: active  
Owner: h-kernel editor / Household application  
更新日: 2026-08-11

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

日常操作では、canonical Account名、PlanId、event-idなどを人間へ暗記させない。workspaceがtyped identityを保持し、表示Textからidentityを再構築しない。

keyboard operationは完全に保ち、mouseは同じvisible objectへの短い入口として使える。click-only mutationは作らない。

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

## Current practical priorities

優先順位はHouseholdを実際に使う頻度と不便さで決める。

1. ordinary / multi-posting Recordを一つの自然なflowへ近づける
2. Plan completion / successor replenishmentを選択中Planから短く完了する
3. Reportを見たい対象へ迷わず到達できるようにする
4. Account / Budget / Issue / Plan maintenanceを各workspaceのcontextual operationとして完結させる
5. repeated typing、canonical-string recall、不要なmodal traversalを減らす
6. 実測で問題があるruntime pathだけを性能改善する

新しい機能へ進む前に、current codeとremoteを確認する。この文書の列挙を実装済み状態の代わりに使わない。

## Non-goals

- generic command framework
- generic form DSL
- generic repository/session abstraction
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
