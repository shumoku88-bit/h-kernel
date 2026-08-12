# Household TUI interaction design

ステータス: active Draft

Owner: Household TUI interaction / Home direction

更新日: 2026-08-12

## 目的

この文書は、Household TUIのcurrent runtime baselineと、実使用から次に観察するinteraction boundaryを所有する。

Editor全体の能力、writer law、delivery ownershipは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)に従う。canonical source shapeは[`HOUSEHOLD_CANONICAL_SOURCE.md`](HOUSEHOLD_CANONICAL_SOURCE.md)、writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。この文書からsource ownershipやwriter authorityを推測して変更しない。

基本原則は次である。

> **Domainは分ける。人間の行動は必要以上に分けない。**

TUIをfeature menu、generic Hub、screen frameworkから設計しない。Householdの日常行動から設計し、exact arithmetic、identity、provenance、admission、publication lawを保ったまま、開始時の不要な分類、canonical文字列の暗記、余分な画面遷移を減らす。

## Current runtime baseline

### Unified Record

PR #214でActual workspaceに`Record`入口が追加された。

```text
Record = Day + Description + 2 or more Postings
```

Recordはblank 2 postingから始まり、同じinteractionのまま3 posting以上へ増やせる。Expense / Income / Transfer / Multiを開始時に宣言する必要はなく、完成したpostingsとadmitted Account meaningがtransactionを表す。

```text
支出
SMBC    -138
Food     138

収入
SMBC            8000
LessonIncome   -8000

資金移動
Yucho  -10000
SMBC    10000

split
SMBC       -2450
Food        1800
Household    650
```

旧`Expense` / `Income` / `Multi Actual`入口は実使用比較のため現在も残っている。これらを最終UIとして固定しない。

> **1 Record = 1 economic event**

複数postingは一つのeconomic eventを正確に表すために使う。unrelated eventsのbatchには使わない。連続入力が必要ならtransaction boundaryを壊さず、実使用の証拠を得てから`Save & next`等を検討する。

### Account chooser

PR #214でRecordのAccount chooserはSearchとBrowseが一つのinteractionになった。

- 空queryでは全admitted Accountsをbrowseできる。
- text inputは同じ候補集合をcase-insensitive substring filterする。
- recent-first assistanceとtyped `AccountType` groupingを保つ。
- raw Account Textはqueryとして残る。
- TUI-local candidate cursorだけをUp / Downで動かす。
- Enterでhighlight候補をcommitする。
- mouse clickも同じfiltered candidate resolverを使う。
- query変更とposting row変更でcursorをresetする。
- stale / out-of-range cursorはno-opになる。

filtering / ranking / cursorはpresentation assistanceであり、Account identityやtransaction semanticsのauthorityではない。最終的なAccount meaning、Commodity、balance、transaction validityは既存domain admissionが決める。

### Reports surface

PR #215でinteractive TUIのReportsから、owner sectionと重複する次のviewを外した。

- Planned Transactions
- Open Issues
- Recent Actual
- Full Household Report

underlying rendererやCLI/export publicationは残っている。

この変更から、TUIのsurface boundaryを次のように読む。

```text
Home      -> 今なにを見る / する必要があるか
Section   -> Actual / Plan / Issue等のobjectを扱う場所
Reports   -> object群から導いた分析・集計
```

同じobject listを複数sectionへ複製しない。

### まだ実使用で観察するRecord interaction

row-local posting edit、add/remove row grammar、balancing remainder suggestion、`Save & next`、transfer convenienceはまだ確定しない。

現行Recordを実際に使い、操作上の摩擦が具体化したものだけを直す。generic table / Form / navigation frameworkを先に作らない。

## Home direction

Homeはfeature menuではなく、**同じcanonical Household observationから作る現在状態のprojection**とする。

Home自身のcanonical sourceやHome専用Factを作らない。

候補surface:

```text
Household                         Aug 12

Attention
  ! Aug 10  Refund waiting             Issue
  ! Aug 12  Electricity                Plan
    Aug 15  Subscription review        Issue

Cycle
  18 days remaining
  Daily capacity    ...

Accounts
  SMBC              ...
  Yucho             ...

Latest
  Aug 12  Supermarket                  Record

[r] Record
```

### Homeが答える問い

Homeが答えるのは「機能は何があるか」ではなく、次のような問いである。

- 期限を過ぎた / 近いものは何か。
- 今日注意が必要なPlan / Issueは何か。
- current cycleはどこまで来ているか。
- 日常判断に必要なAccount stateは何か。
- 最後に何を記帳したか。
- 今すぐRecordを始めたいか。

### Homeはownerにならない

Homeに表示したPlanを選べばPlans sectionのそのPlanへ移動する。IssueならIssues sectionへ、RecordならActual sectionへ移動する。

```text
Home attention item
  -> stable object identity
  -> owning section
```

Homeでobjectを複製編集しない。direct navigationのためにdescription、日付、金額の近似一致をidentity代わりにしない。

stable identityが存在しないobjectについては、先にidentity semanticsを確認する。navigation都合だけでsource lineやlist indexをdurable identityへ昇格させない。

### Attentionはprojection

`Attention`は新しいcanonical data kindではない。Plan、Issue、cycle等のadmitted stateから、その観察日に注意すべきものを導くprojectionである。

最初から万能`AttentionItem` domainやrule engineを作らない。Home実装時に必要なfiniteなderived viewだけを置く。

## Issueと他データのrelation observation

### Current Issue boundary

現在の`HouseholdIssue`は独立したHousehold matterである。

```text
IssueId
recordedOn
status       Open / Resolved / Dropped
due          DueOn Day / DueUndetermined
amount       optional
text
details
```

IssueはJournal fact、Plan commitment、Budget movement、diagnosticではなく、それ自体ではbalanceやbudget resultを変えない。この境界を維持する。

Issueのamountは「その時点でIssueに記録したamount」であり、後のPlan / Actual / Budget movementの値を複製する場所にしない。

### Relationの基本法則

Issueが後の行動へつながる場合、結果の内容をIssueへコピーせず、必要な関係をidentity / provenanceとして表す。

```text
Issue
  -> Plan
  -> Actual

Issue
  -> Actual

Issue
  -> Budget movement
  -> Plan / Actual
```

ただし、これを理由にgeneric graph database、universal `RelatedObject`、universal Household Journalを先に作らない。

relationの意味は具体的であるべきで、少なくとも次を区別できる必要がある。

- このIssueからPlanを作った。
- このActualがIssueに関係する結果だった。
- このBudget movementがIssueへの資金手当だった。
- relationが存在してもIssueをResolvedにしたとは限らない。

`Resolved` / `Dropped`はIssue ownerの明示的状態であり、ActualやPlanの存在から自動推論して書き換えない。UIがresolveを提案することは将来検討できる。

### 現在存在するidentity

#### Issue

`IssueId`はstable machine identityとして既に存在する。

#### Plan

`PlanId`はdurable identityであり、後のActual evidenceとdate / memo / amountの推測なしに関係を結ぶために存在する。

したがって`Issue -> Plan`は、relationを初めて具体化する候補として比較的自然である。

#### Actual

Actual側には`ActualTransactionId`があるが、**すべてのActualがdurable identityを持つわけではない**。

- explicit `event-id`を持つActualはdurable identityを持つ。
- Plan completion relationからrebuildable runtime identityを持つ場合がある。
- ordinary identity-free Actualも正規に存在する。

したがってIssueからordinary Recordへdurable relationを要求する場合、「現在たまたま同じdate / description / amountだから結ぶ」は不可である。

具体的なIssue-to-Actual workflowを実装する時点で、そのRecordへdurable identityを与える必要があるか、既存Actual metadata ownerへどう接続するかをfinite sliceとして決める。

#### Budget movement

現在の`HouseholdBudgetMovement` valueはdate / memo / from / to / amountを持つが、stable BudgetMovementIdは持たない。native Budget Journalはordered root transaction source evidenceを保持するが、source lineやlist indexをdurable identityとして扱わない。

Issue-to-Budget relationが本当に必要になった時点で、Budget movement側のidentityを追加する必要があるかを観察する。HomeやIssue UIの都合だけで先回りしてIDを追加しない。

### Relation evidenceの保存

関係が長期に積み上がり、後から「当時どう判断して何につながったか」を読む必要がある場合、current TOMLや現在値だけで過去の意味を書き換えない。

relation historyはmutableな表示用projectionではなく、必要ならexplicit durable evidenceとして残す。ただしexact source formatとownerはまだ決定しない。

特に避ける。

- IssueへPlan/Actualのamountやpostingをコピーする。
- 現在のcategory / policy設定から過去のrelationを再推測する。
- date / memo / amountの近似一致でrelationを確定する。
- source line番号をrelation identityにする。
- すべてのrelationを一つのgeneric event schemaへ押し込む。

## Homeとrelationが交わる場所

Homeはrelationを所有しないが、relationを読むことで「次に何を見るべきか」をより自然に表せる。

例:

```text
Refund waiting
  due Aug 14
  no related Actual yet

Laptop
  related Plan: Aug 20
  not completed

Subscription review
  due tomorrow
  related prior Actual available
```

これはIssue / Plan / ActualをHomeへ複製することではない。Homeは各ownerのstateとrelation evidenceから短いattention projectionを作るだけである。

最初のHome実装でrelationが未実装なら、due / status等の既存typed stateだけで始めてよい。Homeを作るためにrelation system完成を前提にしない。

## Historical evidence and current policy

Interaction convenienceはFact、Policy / Decision、Projectionの境界を変えない。正規境界は[`FACT_POLICY_PROJECTION_BOUNDARY.md`](FACT_POLICY_PROJECTION_BOUNDARY.md)が所有する。

- current policyはcurrent / future candidateを導く。
- durable historical evidenceは、その時に起きたことや明示的に決めたことを記録する。
- current analytical projectionは、現在のpolicyから再計算され得る。

current TOMLを編集しただけでdurable Actual、Plan、Budget decision、Issue relation、identity / provenanceを暗黙に書き換えない。

## 次の観察順序

1. **Recordを日常利用し、操作上の摩擦を記録する。**
2. **Homeの最小projectionを定義する。** まず既存typed stateだけでAttention / Cycle / Accounts / Latest / Record入口を構成できるか観察する。
3. **Home direct navigationに必要なidentityを列挙する。** 既存identityで足りない箇所を近似一致で埋めない。
4. **Issue -> Plan relationを最初の具体的relation候補として観察する。** 必要なprovenanceとlifecycleを確認する。
5. **Issue -> Actual / Budget relationは実use caseが要求してからfinite sliceで設計する。**
6. row-local edit、`Save & next`、balancing assistance等はRecord実使用から必要性が確認されたものを進める。

Homeとrelationを同じPRで一気に実装しない。まず観察結果を積み上げ、Home projection自体はrelation systemなしでも成立するようにする。

## Completedとして扱う項目

次はfuture TODOへ戻さない。

- Unified Recordの2+ posting runtime path (#214)
- Search / Browse一体のRecord Account chooser (#214)
- Account raw queryとTUI-local candidate cursorの分離 (#214)
- keyboard / mouseが同じfiltered Account candidate setを使うこと (#214)
- `ActualMultiAddInput`へのauthoritative draft一本化
- selected posting row / unfinished posting-count textのTUI-local ownership
- Actual / Plan / Report等のsection-local TUI ownership
- concrete Plan Budget-sync picker ownership
- TUI Reportsからowner sectionと重複するobject viewsを除外 (#215)
- generic Hub / 三層quota / file-size基準のmodule splitting planの撤回

completed historyの詳細はGitとmerged PRが所有する。この文書へ旧state、作業日誌、完了済みmigration手順を蓄積しない。

## 未決定

- Homeのdue-soon threshold
- Homeへ表示するAccount subsetと選定根拠
- Attentionのordering
- Homeでlatest Recordを何件見せるか
- direct navigationのexact keyboard / mouse grammar
- Issue relation evidenceのsource owner / source format
- Issue -> Plan relationのdirection / lifecycle wording
- ordinary ActualへIssue relationを持たせる場合のdurable identity方針
- Budget movement relationが必要な場合のidentity方針
- relationからIssue resolveを提案するUX
- exact row / cell focus grammar
- add / remove posting controlのexact grammar
- balancing remainderを提案できる条件
- `Save & next`の必要性とgrammar
- mandatory modeを戻さないtransfer convenience

## Non-goals

- このPRでのHaskell runtime変更
- Home専用canonical source
- generic relation graph / event store
- accounting semanticsの変更
- source format migration
- writer authority cutover
- generic navigation / Form / picker / fuzzy-search framework
- architecture diagram、module symmetry、LOCのためのrefactor

このDraftを実装する各runtime PRはcurrent mainから始め、一つのcoherent interaction changeとしてfocused test、full test、repository audit、final diffを確認する。
