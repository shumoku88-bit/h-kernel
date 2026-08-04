# h-kernel Editor 開発設計面

ステータス: アクティブな開発設計面  
Owner: h-kernel editor  
Canonical: yes  
更新条件: editorのmain能力、次の有限slice、component境界、writer authority、cutover gateが変わるとき

## 1. この文書の役割

この文書は、`h-kernel`自身のeditorを段階的に育てるための正規ownerである。

coding assistantは、作業開始時にこの文書を読み、次を同じ現在地から判断する。

- mainにmerge済みのeditor能力
- 次に扱う一つの有限slice
- coreとeditorの共有境界
- 触れてよいpathと並行作業の境界
- source mutationへ進むための安全条件
- bqn-ledgerから引き継ぐ観察可能な行動
- h-kernelへwriter authorityを移すためのgate

この文書へbranch名、日ごとの作業記録、試行錯誤の履歴を蓄積しない。open PRとbranchの状態はGitHubが所有し、過去の設計はGit履歴が所有する。各editor PRは、mainへ追加される能力と次のsliceが変わる場合だけ、この文書のCURRENTとNEXTを現在形へ更新する。

## 2. 現在地

### CURRENT

```text
canonical source     separate private data repository
current writer       bqn-ledger editor
current h-kernel role reader/report engine + explicit Actual editor CLI
h-kernel write path  h-kernel-editor-cli --commit for rehearsal only
editor component     ActualAppend + ActualWriter + independent CLI
```

- 外部private directoryは一つだけの正規世帯sourceである。
- bqn-ledger editorが現在のcanonical write effectを所有する。
- `h-kernel-editor-cli`がargumentsからtyped intentを作り、previewを常に表示し、明示`--commit`の場合だけsafe writerへ委譲する。
- commandは対象Journal pathを明示し、private sourceをdefaultとして推測しない。
- focused testとrehearsalはsynthetic temporary sourceだけを変更する。
- interactive UIとtransaction reverseはまだ実装していない。
- writer authorityは、明示的なcutover PRがmergeされるまで移動しない。

詳細なsource ownershipは[`SOURCE_DATA_MIGRATION_PLAN.md`](SOURCE_DATA_MIGRATION_PLAN.md)が所有する。

### NEXT

次の有限sliceは、既存transactionをidentity/provenanceごと選び、新しいreversal transactionとしてappendするE4である。

```text
selected existing transaction
  -> typed reversal intent
  -> reversed ordered postings
  -> complete-source preview
  -> existing safe writer
```

original transactionの破壊的変更、interactive UI、writer authority cutover、他sourceのmutationを混ぜない。

## 3. bqn-ledgerとの関係

bqn-ledger editorは、h-kernel editorのコード移植元ではない。日常運用で観察済みの行動仕様、安全境界、command vocabularyを確認する先である。

h-kernelでは、既存のHaskell型、smart constructor、Journal admission、Account registry、exact Moneyを使い、同じ行動をHaskell固有の構成で育てる。

### 目標に含む行動

- Actual Journalへのordinary two-posting append
- native multi-posting append
- transaction reversalを新しいtransactionとしてappend
- Account declarationの追加
- Budget movementの追加
- Household Issueの追加
- Planの追加、選択、修正、完了、関連Planの観察
- dry-run preview
- stale source拒否
- backup、atomic publish、post-admission、recoverable restore
- thin command surface
- optional interactive orchestration

### 現時点で目標に含めない行動

- h-kernelにdomain ownerがない旅行固有sourceのwrite path
- editorによるAccountまたはCommodity declarationの暗黙生成
- Report計算をeditor内へ複製すること
- bqn-ledgerのmodule構造、BQN表現、shell構造の機械的な移植
- source migrationとwriter cutoverを通常の機能追加へ混ぜること

旅行固有sourceなどを追加する場合は、editor commandより先に、その事実とsourceのstable ownerを別sliceで合意する。

## 4. Componentと共有境界

### 4.1 物理的なcomponent境界

h-kernel editorは、同じrepositoryとCIを共有しながら、main accounting libraryとは別のCabal componentとして置く。

```text
h-kernel
  source: src/
  owns: Account, Money, Ledger, Journal, Actual, Plan, Budget, Report

h-kernel-household
  source: household-src/
  depends on: h-kernel
  owns: Household policy, Backing, Budget movement, Issueなど

h-kernel-editor
  source: editor-src/
  depends on: h-kernel
  later may depend on: h-kernel-household when a named Household source requires it
  owns: edit intent, preview, source placement, safe write effect

h-kernel-editor executable
  source: editor-app/
  depends on: h-kernel-editor
  owns: CLI and process boundary
```

依存方向は一方向にする。

```text
h-kernel-editor -> h-kernel
h-kernel-editor -> h-kernel-household   only when a later named slice requires it
h-kernel -> h-kernel-editor             forbidden
h-kernel-household -> h-kernel-editor   forbidden
Report -> h-kernel-editor               forbidden
```

Editor固有のIO依存、filesystem操作、CLI parserをmain libraryへ漏らさない。別repositoryには分けず、同じ型、同じ正規source、同じrepository audit、同じCIの中で所有権を分ける。

### 4.2 coreから共有する部品

Editorは次の会計意味を再実装せず、既存ownerを使う。

- `HKernel.Account`の`Account`、`AccountDeclaration`、`AccountRegistry`
- `HKernel.Money`の`Commodity`、`Quantity`、`Amount`、`Balance`
- `HKernel.Ledger`の`Posting`、`Transaction`、`mkTransaction`
- `HKernel.Journal`のstrict parser、Account declaration、complete-source validation
- `HKernel.Actual.Journal`のActual metadata admission
- Plan、Budget、Household Issueについて既に存在するtyped ownerとsmart constructor

Editorは簡易Account validator、独自Money型、別のbalance判定、簡易Journal parserを持たない。候補source全体をstable admissionへ戻すことで、readerとwriter candidateが同じ意味を共有する。

### 4.3 Editorに独立させる部品

次はeditor固有の責任であり、会計coreへ入れない。

- `ActualEditIntent`などのuser/application intent
- append、replace、reverseの候補操作
- candidate source fragmentとcomplete-source preview
- source末尾、空行、metadata配置などのsource placement
- stale check、backup、temporary file、atomic publish、restore
- dry-runとconfirmation用のpresentation
- CLI argument、exit status、interactive orchestration

会計意味を共有することと、編集手続きを一つのmoduleへ混ぜることは別である。

### 4.4 共有部品へ昇格する条件

最初から`GenericEditorFramework`を作らない。Actualで生まれたhelperがBudget、Issue、Planでも使えそうに見えても、同じ責任、同じ失敗、同じeffect順序を持つことを確認してから共有ownerへ上げる。

Editor内部で共有され得る候補は次である。

```text
expected old bytes
  + validated new bytes
  -> stale check
  -> backup
  -> sibling temporary file
  -> atomic publish
  -> post-admission
  -> restore-capable result
```

このwrite effectはsourceの会計意味を知らず、sourceごとのpost-admission関数を受け取る形になり得る。ただしE2でActual writerとして証拠を得る前に抽象化しない。

validated `Transaction`をnative Journal blockへ表すpure rendererは、Editor以外にも同じ正規表現が必要だと確認できた場合、将来`HKernel.Journal.Render`のようなcore ownerへ昇格し得る。一方、metadata追加、append位置、source末尾、preview構成はEditor側に残す。

```text
validated accounting valueの正規構文表現   shared core候補
sourceへどう配置し、どう安全に公開するか    Editor固有
```

共有化は行数削減ではなく、意味のownerを一つにするために行う。

## 5. Editorの声部

Editorを一つの巨大な手続きへまとめない。少なくとも次の声部を分ける。

### 5.1 Intentと候補生成

```text
user/application intent
  -> typed edit intent
  -> domain validation
  -> candidate source fragment
```

- pure functionを中心に置く。
- invalid stateをADT、opaque constructor、smart constructorで入口から減らす。
- transaction内のposting順、identity、Commodity、exact Quantityを保持する。
- generic editor frameworkを先に作らない。

### 5.2 Complete-source admission

```text
existing source
  + candidate fragment
  -> candidate complete source
  -> existing stable parser
  -> typed complete source
```

候補fragmentだけを正しいと見なさない。追記後のsource全体を、現在のstable admissionで再検証する。

### 5.3 Write effect

```text
validated candidate
  + expected old bytes
  -> stale check
  -> backup
  -> sibling temporary file
  -> atomic publish
  -> post-admission
  -> success or recoverable failure
```

- domain validationが失敗した場合はsourceへ触れない。
- read時のbytesとpublish直前のbytesが異なる場合は拒否する。
- backup、temporary file、rename、restoreは会計意味を所有しない。
- publish後の再admissionに失敗した場合は通常運用を継続せず、復旧可能な状態を保つ。
- backup、recovery artifact、local logをGitへcommitしない。

### 5.4 Command surface

command layerはtyped intentを構築し、previewまたはwriterへ渡す。Account、Money、Journalの意味を再実装しない。

Editor初期段階では既存の`app/Main.hs`へcommandを足さず、独立した`editor-app/` entrypointを使う。main report CLIとeditor effectを早期に結合しない。

### 5.5 Interactive orchestration

fzf、gum、番号選択、prompt、候補表示はcommand surfaceの外側に置く。interaction layerはAccount分類、Plan完了、balance、source mutationの意味を所有しない。

## 6. 最初の有限slice: Actual append preview

### Domain phrase

編集要求は、既存のAccount declaration、Commodity、exact Quantity、posting balance、完全source admissionを通過するまでActual Transactionではない。

### Domain structure

- 既存Actual Journal source
- transaction date
- description
- ordered non-empty postings
- declared Account identity
- Accountのdefault Commodity evidence
- exact signed Quantity
- Commodityごとのzero balance
- candidate native Journal block
- candidate complete source
- source-local failure

### Haskell phrase

- ordinary transferとmulti-postingを表す小さなedit intent ADT
- posting不足を避ける`NonEmpty`
- 既存の`Account`、`Commodity`、`Quantity`、`Amount`、Journal型とsmart constructor
- 形と順序を保つ`traverse`
- Commodityごとのbalanceを名前付きpure functionで検証
- native Journal blockを返すrender boundary
- candidate complete sourceを既存parserへ戻す再admission
- IOを含まない中心関数

### Correspondence

- Account文字列や金額文字列を後段まで流さない。
- ordinary transferとmulti-postingの共通部分はtyped postingsで共有するが、異なるuser intentを一つのflag recordへ潰さない。
- posting順はrenderingと人間の読解に意味を持つため保持する。
- 複数Commodityを一つの総和で相殺せず、Commodityごとにbalanceを観察する。
- candidate blockとcandidate complete sourceをpreviewから読めるようにする。

### Rejected phrases

- source mutationを最初のsliceへ含める
- editor用の独自AccountまたはMoney型を作る
- writerが不足するdeclarationを自動生成する
- generic TSV/Journal editing frameworkを先に作る
- bool flagの組合せでordinary、multi、reverseを一recordへ押し込む
- cross-Commodity totalがzeroならbalancedとみなす
- E1からmain libraryへEditor固有moduleを置く

### Evidence

- ordinary two-posting preview
- three-posting preview
- posting順の保持
- exact finite decimalの保持
- undeclared Account rejection
- Account default Commodity mismatch rejection
- zero ordinary amount rejection
- posting不足 rejection
- unbalanced rejection
- cross-Commodity balancing rejection
- candidate complete sourceの再parse
- 元sourceが変更されないこと
- `h-kernel`と`h-kernel-household`が`h-kernel-editor`へ依存しないこと

中心境界の名前は実装前のrepository観察で調整してよい。形の目安は次である。

```haskell
prepareActualAppend
  :: Text
  -> ActualEditIntent
  -> Either (NonEmpty ActualEditError) ActualAppendPreview
```

`Day`、typed Account、typed Quantityをintent構築前に要求するか、command boundaryで文字列をadmitするかは、既存public APIと診断ownerを読んで決める。coreとCLI parsingを一つの関数へ混ぜない。

## 7. 段階順序

| 段階 | 能力 | 開始条件 |
|---|---|---|
| E1 | 独立`h-kernel-editor` componentとActual appendのpure preview | この設計面と既存Actual/Account admission |
| E2 | safe single-file writer | E1のcandidate complete sourceとerror contractがstable |
| E3 | Actual add / multi-add command | E2のstale、backup、atomic publish、restore evidence |
| E4 | transaction reverse | E3とtransaction identity/provenanceの合意 |
| E5 | Account / Budget / Issue append | 各stable ownerとsourceごとのappend contract |
| E6 | Plan add / select / edit / finish | Plan identity、completion、exact replaceの安全契約 |
| E7 | interactive orchestration | 日常command surfaceがstable |
| E8 | writer cutover | parity、運用試験、rollback、作者の明示承認 |

段階番号は依存順を示す。複数能力を一つのPRへまとめる理由にはしない。E5内でもAccount、Budget、Issueは別sliceにできる。

## 8. 並行作業の境界

### Editor laneが優先して使用するpath

```text
editor-src/HKernel/Editor/**
editor-app/**
tests/Editor*
docs/EDITOR_DEVELOPMENT_PLAN.md
```

### 共有path

```text
h-kernel.cabal
AGENTS.md
docs/INDEX.toml
docs/CODE_MAP_AND_DESIGN_SKETCH.md
```

共有pathを変更する前に最新mainとopen PRを再確認し、必要最小限の接続だけを行う。並行branchの完成内容を上書きしない。

`src/HKernel/**`と`household-src/HKernel/**`は再利用するpublic APIのownerであり、Editor laneの予約領域ではない。Editor実装中にcore API変更や共有rendererへの昇格が必要になった場合は、Editor sliceへ便乗させず、作者と合意した独立sliceに分ける。

### Editor sliceで通常は触れないpathとsource

```text
external private household source
household-src/**
spike-src/**
app/Main.hs
src/HKernel/Report/**
workflow files
```

実装上必要に見えても、sliceの意味が広がる場合は先に作者との設計合意へ戻る。特にprivate household source変更、writer authority変更、Report変更はeditor実装へ便乗させない。

## 9. Coding assistantの開始手順

Editor作業を始めるassistantは、実装前に次を行う。

1. remoteの最新main SHA、open PR、直近commit、関連branchを確認する。
2. `AGENTS.md`、この文書、`HASKELL_NATIVE_CODE_POLICY.md`、`PLATFORM_NEUTRAL_APPLICATION_POLICY.md`、`SOURCE_DATA_MIGRATION_PLAN.md`を読む。
3. bqn-ledgerの現在のeditor documentationとcommand behaviorを観察する。コードを正本としてコピーしない。
4. mainへmerge済みのeditor能力とNEXTを、この文書から確認する。
5. Editor lane、共有path、core public APIについて、open PRの変更fileとの重複を確認する。
6. 一つのcoherent finite sliceだけを選び、Draft PRで開始する。
7. PR本文へ二重譜読みとcomponent依存方向を記録する。
8. CI成功後も自動mergeしない。

mainの状態とこの文書が矛盾する場合、推測で実装を進めない。コード、test、merged PRを確認し、この文書を現在形へ直すsliceを先に行う。

## 10. Editor PRの完了条件

各PRは、対象sliceに応じて次を満たす。

- Domain phraseとHaskell phraseが実際の型、data flow、testに一致する
- publicまたはcomponent ownerが一つに定まる
- coreからEditorへの逆依存がない
- EditorがAccount、Money、balance、Journal admissionを再実装していない
- focused testが成功する
- `cabal build all`
- `cabal test all`
- `cabal run repository-audit`
- Reportまたは正規sourceへ影響し得る場合はcomplete report contractsを確認する
- GHC 9.10.3、9.12.4、9.14.1のCIを確認する
- external private household sourceへ未合意の差分がない
- writer authorityが暗黙に変わっていない
- main能力またはNEXTが変わる場合、この文書を現在形へ更新する
- Ready化とmergeは作者の明示許可を待つ

## 11. Writer cutover gate

h-kernel editorへwriter authorityを移すPRは、通常のcommand追加と分ける。

cutover前に少なくとも次の証拠を揃える。

- 日常利用に必要なcommand setについてbqn-ledgerとの行動parityがある
- strict source admission、Account declaration、exact Quantity、Commodity、balance、identity、provenanceを維持する
- dry-runと最終confirmationがある
- stale sourceを拒否する
- backup、atomic publish、post-admission、restoreがfailure testで観察できる
- synthetic sourceと正規sourceのcopyを使った運用試験がある
- bqn-ledgerとh-kernelの同時writeを防ぐ運用変更がある
- rollback手順が一つの正規sourceを前提としている
- synthetic Report contractと、明示したprivate sourceのlocal admissionが成功する
- 作者がcutoverを明示的に承認する

cutoverが完了するまで、bqn-ledger editorがcurrent writerであり、h-kernel editorはpreview、test、非正規fixture、明示的な試験環境だけを対象にする。
