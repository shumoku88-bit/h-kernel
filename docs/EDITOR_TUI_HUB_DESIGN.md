# Household TUI interaction design

ステータス: active Draft

Owner: Household TUIの日常記帳interaction

更新日: 2026-08-12

## 目的

この文書は、Household TUIにおける日常記帳のcurrent runtime baselineと、次に実装するinteraction targetを所有する。

Editor全体の能力、writer law、delivery ownershipは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)に従う。canonical source shapeは[`HOUSEHOLD_CANONICAL_SOURCE.md`](HOUSEHOLD_CANONICAL_SOURCE.md)、writer authorityは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。この文書からsource ownershipやwriter authorityを推測して変更しない。

基本原則は次である。

> **Domainは分ける。人間の行動は必要以上に分けない。**

TUIをfeature menu、generic Hub、screen frameworkから設計しない。Householdの日常行動から設計し、exact arithmetic、identity、provenance、admission、publication lawを保ったまま、開始時の不要な分類、canonical文字列の暗記、余分な画面遷移を減らす。

## Current runtime baseline

current mainのActual workspaceには、開始時点で次の三つの入口がある。

```text
Expense
Income
Multi Actual
```

ordinary Expense / Incomeは共通のtwo-posting inputを使うが、`DailyEntryKind`で入口とAccount roleを分けている。Multi Actualは別のformとして始まり、最低3 postingを保持する。したがってUnified Recordはまだruntimeに実装されていない。

### 実装済みのownership

Multi Actualのduplicate draft ownershipは解消済みである。

```text
ActualMultiAddInput
  -> date、description、全postingを持つauthoritative draft

TUI-local MultiFormState
  -> selected posting row
  -> unfinished posting-count text
```

Brick lensは選択中postingのAccount / Amountを`ActualMultiAddInput`へ直接反映する。古い`ActualMultiAddState`やduplicate form bridgeをfuture workとして復活させない。

Actual、Plan、Reportなどのsection-local interactionもconcrete TUI ownerへ移っている。`Main`を特定行数へ縮めるためのmodule split、三層quota、generic navigation、shared Form / picker frameworkはtargetではない。新しいownerは実在するinteractionまたはeffect boundaryがある場合だけ置く。

### 現在のAccount discovery

current runtimeはAccount fieldへfocusしたとき、admitted Accountsからinline候補を表示する。

- Daily ExpenseはExpense destinationとAsset / Liability payment sourceを分ける。
- Daily IncomeはAsset destinationとIncome sourceを分ける。
- Multiは全admitted Accountsを候補にできる。
- recent Actual useを先にrankする。
- `AccountType`によるstable groupingを使い、Account名prefixからtypeを推測しない。
- Up / Downで候補を移動し、Enterで受け入れる。
- exact Account textの入力もfallbackとして残る。

pure interaction ownerには次が存在する。

```text
filterDailyAccountCandidates
filterMultiAccountCandidates
filterAccountCandidates
```

前二つは`filterAccountCandidates`を共有し、trimしたqueryによるcase-insensitive substring filterを行う。空queryでは入力順を保持する。

ただしcurrent Brick runtimeは、Account fieldの部分文字列をinline候補へまだ適用していない。候補rowのmouse clickもAccount chooserには未接続である。したがって「入力しながらfilter」と「同じ一覧をmouseで選択」は次のruntime targetであり、実装済みとは扱わない。

## Immediate target: Unified Record

Expense / Income / Transfer / Multiを開始時点の別modeにしない。

interaction上のRecordを次として扱う。

```text
Record = Day + Description + 2 or more Postings
```

2 postingsはordinary Recordの最小形である。economic eventが必要とするときだけ、同じinteractionの中で3、4、それ以上へposting rowを増やす。

UIは最初に「支出か」「収入か」「資金移動か」「Multiか」を宣言させない。完成したpostingsとadmitted Account meaningがtransactionを表す。

### 支出

```text
SMBC    -138
Food     138
```

### 収入

```text
SMBC            8000
LessonIncome   -8000
```

### 資金移動

```text
Yucho  -10000
SMBC    10000
```

### 3 postings以上

```text
SMBC       -2450
Food        1800
Household    650
```

Transfer向けの補助を後から加えても、mandatoryな`Transfer mode`を開始時の分岐として戻さない。

## Record identity boundary

> **1 Record = 1 economic event**

複数postingは一つのeconomic eventを正確に表すために使う。unrelated eventsのbatchには使わない。

同じ日に独立した収入や支出が複数あれば、別々のRecordとして残す。

```text
morning lesson payment -> Record A
other lesson payment   -> Record B
```

連続入力を速くする必要がある場合は、transaction boundaryを壊さず、実使用の証拠を得てから`Save & next`のようなinteractionを検討する。

## Row-local posting interaction

Unified Recordでは、visible posting rowまたはcell自体を編集対象として理解できる形を目指す。

```text
Description: Supermarket

Account                               Amount
> SMBC                                 -2450
  Food                                  1800
  Household                              650
```

current Multi formのように、rowを選んだ後でshared `Selected account` / `Selected amount` fieldへ移動し、各rowのたびにunrelated fieldを巡回する間接性を減らす。

候補grammarは次であるが、実使用前に確定しない。

- Up / Down: posting rowまたはchooser候補の移動
- Tab / Left / Right: Account / Amount cellの移動
- Enter: chooser acceptまたはpreview
- mouse: visible row / candidateの選択
- add / remove row:同じRecord内のposting数変更

row-local interactionのためにgeneric table frameworkや新しいshared cursor ownerを先に作らない。`ActualMultiAddInput`をauthoritative draftとして保ち、focus、cursor、unfinished inputはdelivery ownerへ置く。

## Account chooser: SearchとBrowseは一つ

Account selectionを`Search Account`と`Browse Accounts`の別modeにしない。一つのchooserが、同じadmitted Account集合をqueryに応じて表示する。

```text
empty input
  -> admitted Accountsをbrowse

text input
  -> 同じ一覧を即時filter
```

### 空欄

空欄では、名前を覚えていなくてもAccountを発見できるようにする。

- admitted Accountsの一覧
- recent Accounts
- `AccountType` grouping
- Up / Down + Enter
- mouse row click

Recentとgroupingはpresentation assistanceであり、Account identityの新しいownerではない。同じAccountを重複したsemantic valueとして作らず、typed `Account` identityを選択結果として保つ。

### Search as you type

通常文字の入力をそのままqueryとして扱い、同じ一覧をcase-insensitive substring filterする。

```text
s   -> SMBC、Savings、ほかの一致候補
sm  -> SMBCを含む、より短い候補集合
smb -> SMBC
```

既存の`filterDailyAccountCandidates`、`filterMultiAccountCandidates`、`filterAccountCandidates`を最初のownerとして使う。新しいfuzzy-search engine、score framework、別search stateを作らない。

filter後も次を保つ。

- admitted Accountだけを候補にする
- current Daily roleまたはMulti candidate lawを保つ
- recent-first orderingを壊さない
- groupingはtyped `AccountType`から作る
- Up / Down、Enter、mouse clickが同じ候補集合を扱う

queryが空ならbrowseへ戻る。SearchからBrowseへ移るmode切替commandは設けない。

### Authority boundary

候補filterとrankingはassistanceであり、Account identityやtransaction semanticsのauthorityではない。

```text
admitted Account candidates
  -> filter / recent ranking / typed grouping
  -> human selection
  -> typed Account identity
  -> existing Actual candidate admission
```

候補順からExpense、Income、Transferを確定しない。raw textを許す間も、最終的なAccount meaning、Commodity、balance、transaction validityは既存domain admissionが決める。

## Defaults and Commodity

Household primary Commodityはcommon interactionを短くするdefaultであり、domain restrictionではない。canonical coordinateは`household.toml`からtyped `Commodity`としてadmitされる。

```text
explicit Commodity
  -> otherwise one unambiguous selected-Account default
  -> otherwise Household primary Commodity
  -> otherwise explicit choice / fail closed
```

selected Account defaultsが衝突する場合、Household primary Commodityで上書きしない。UIで省略できるのは入力上の反復であり、publishされるAmountのCommodityではない。

current Plan / Budget / Account formsにはadapter-localな`JPY`初期値が残っているため、すべてがHousehold primary Commodityへ接続済みとは扱わない。Commodity wiringはUnified Recordへ無関係なsource migrationやwriter authority変更と混ぜない。

## Historical evidence and current policy

Interaction convenienceはFact、Policy / Decision、Projectionの境界を変えない。正規境界は[`FACT_POLICY_PROJECTION_BOUNDARY.md`](FACT_POLICY_PROJECTION_BOUNDARY.md)が所有する。

- current policyはcurrent / future candidateを導く。
- durable historical evidenceは、その時に起きたことや明示的に決めたことを記録する。
- current analytical projectionは、現在のpolicyから再計算され得る。

current TOMLを編集しただけでdurable Actual、Plan、Budget decision、identity / provenanceを暗黙に書き換えない。IssueからPlan / Actualへの将来の関係も、amountやpostingをIssueへ複製せず、具体的ownerを確認してidentity / provenanceで結ぶ。

このinteraction Draftからgeneric event store、universal Household Journal、configuration versioning frameworkを導入しない。

## Home direction

Homeはfeature menuではなくHousehold stateのprojectionとする。

候補:

- overdue / due-soon PlanとIssue
- cycle status
- useful Account balances
- latest Record
- visible Household objectからのdirect navigation
- 一つの短いRecord入口

Homeは重要だがruntime targetは後である。先にHomeを実装して、現在のExpense / Income / Multi三入口を固定しない。

## 実装順序

1. **Unified Record**
2. **searchable / browseable Account chooser**
3. **row-local posting interaction**
4. **実使用でRecord grammar、focus、候補順、mouse / keyboard経路を検証**
5. **Home projection / direct navigation**

`Save & next`、balancing remainder suggestion、transfer convenienceは、1〜4の実使用から必要性が確認できた場合に追加する。

## Completedとして扱う項目

次はfuture TODOへ戻さない。

- `ActualMultiAddInput`へのMulti Actual authoritative draft一本化
- selected posting rowとunfinished posting-count textのTUI-local ownership
- Actual / Plan / Report等のsection-local TUI ownership
- concrete Plan Budget-sync picker ownership
- generic Hub / 三層quota / file-size基準のmodule splitting planの撤回

completed historyの詳細はGitとmerged PRが所有する。この文書へ旧state、作業日誌、完了済みmigration手順を蓄積しない。

## 未決定

- exact row / cell focus grammar
- add / remove posting controlのexact grammar
- balancing remainderを提案できる条件
- recentとgroupingの表示重複を避けるpresentation
- filter結果が少ないときにgroup headingを残すか
- `Save & next`の必要性とgrammar
- mandatory modeを戻さないtransfer convenience
- Homeのdue-soon thresholdと表示Account subset

## Non-goals

- このPRでのHaskell runtime変更
- accounting semanticsの変更
- source format migration
- writer authority cutover
- generic navigation / Form / picker / fuzzy-search framework
- architecture diagram、module symmetry、LOCのためのrefactor

このDraftを実装する各runtime PRはcurrent mainから始め、一つのcoherent interaction changeとしてfocused test、full test、repository audit、final diffを確認する。
