# Editor TUI Hub Design Sketch

> **Status**: DRAFT / GROWING DESIGN NOTE
> **Role**: architecture + interaction design
>
> この文書は完成仕様ではない。TUI の実装へ飛びつく前に、日常利用の導線、情報優先度、domain vocabulary と presentation の境界を育てるための設計ノートとして扱う。

## 現在の実装と課題

現在の TUI アプリケーションは、既存機能を Haskell/Brick の画面へ接続してきた一方、日常利用の入口としては「機能を知っている人が機能を選ぶ」構造に寄りやすい。

今後 Report、Issue、Plan lifecycle、Account maintenance などを同じ TUI に載せるとき、機能一覧をそのままハブへ並べるだけでは、画面遷移が増え、日常の記帳や確認まで遠くなる。

この設計では、architecture の分離だけでなく、人間の行動を必要以上に分割しないことを重視する。

## Interaction principles

### 1. Home はメニューではなく「今日の家計の現在地」

起動直後に最初に知りたいのは機能一覧ではなく、今すぐ注意すべきこと、次の cycle までの距離、使える口座残高、最後に何を記帳したかである。

Home は application feature tree を見せる場所ではなく、Household の現在状態から作る read-only projection とする。

### 2. Domain は分けるが、人間の行動は不必要に分けない

Plan、Issue、Actual、Account は domain 上では別 owner であり続ける。

一方、Home 上では「今日注意すべきもの」のような人間の関心で横断してよい。たとえば期限の近い Plan と期限の近い Issue は同じ Attention projection に現れてよい。

### 3. 記帳入口は一つ

通常記帳、split purchase、multi-posting を起点で別機能にしない。

ユーザーは最初に取引種別を宣言せず、ひとつの `Record` から入力を始める。単純な二 posting で終わるならそのまま保存でき、必要になったときだけ posting を追加して三つ、四つへ育てられる。

```text
Record

  Coffee
  ¥138
  SMBC -> Food

  [Enter] Save      [+] Add posting
```

必要なら同じ interaction のまま:

```text
Supermarket

  SMBC             -2,450
  Food              1,800
  Household           650
                   -------
                         0  ✓
```

UI の都合で「simple transaction」と「multi-posting transaction」という別々の mental model を要求しない。

資金移動も、可能なら同じ Record interaction の入力結果として自然に表現できるかを今後観察する。domain semantics の分類を UI の最初の質問にしない。

### 4. 複雑さは必要になったときだけ見せる

日常の最短操作を優先する。詳細 metadata、追加 posting、補助操作は必要になった段階で現れる progressive disclosure とする。

### 5. 色は意味を助けるために使い、唯一の意味伝達手段にしない

色は decoration ではなく semantic presentation として使う。ただし、種類と緊急度を同じ色軸へ押し込めない。

- Issue kind は種類ごとの semantic colour を持ち得る
- due soon / overdue は時間状態として別の emphasis を持つ
- 記号、label、文字列も併用し、色だけを見ないと区別できない UI にしない
- domain model は `red issue` や `cyan issue` のような presentation vocabulary を知らない

## Home draft

### 常時表示候補

- 次の cycle end までの日数
- 各種口座の現在残高
- 最新の記帳 1 件
- 日常操作への短い shortcut

### 条件付き表示候補

- overdue な Plan
- due soon な Plan
- overdue な Issue
- due soon な Issue

Attention が空なら、空の警告枠を常時表示する必要はない。問題や近日対応がある日だけ上部へ現れる静かな layout を目指す。

### First-screen sketch

```text
 h-kernel                                      Aug 10

 Attention
  ! Aug 08  Electricity payment       2 days overdue
  ◇ Aug 12  Internet                  ¥4,800
  ◆ Aug 13  Decide whether to buy chair

 Cycle
  14 days remaining

 Accounts
  SMBC                                  ¥19,333
  Yucho                                 ¥82,400

 Latest
  Aug 10  Coffee · ¥138 · SMBC -> Food

 [n] Record   [p] Plans   [i] Issues   [r] Reports   [?] Help
```

これは固定 wireframe ではない。情報階層と導線を議論するための初稿である。

## Attention projection

Attention は Plan や Issue を一つの domain 型へ潰すものではない。

概念的にはそれぞれの typed owner から「今、人間の注意が必要か」を projection し、Home が presentation 上でまとめる。

```text
Plan ------------------\
                        -> Attention projection -> Home
HouseholdIssue --------/
```

Home から対象を選択したら、その対象を所有する本来の画面へ遷移する。

優先順位の初稿:

1. overdue
2. today
3. due soon
4. cycle status
5. account balances
6. latest entry

`due soon` を何日前から表示するかはまだ決めない。固定値、config、cycle-aware rule のどれが自然かは実利用を観察して決める。

## Household Issue: due date

Domain にはすでに以下の区別が存在する。

```haskell
data IssueDue
  = DueOn Day
  | DueUndetermined
```

これは「期限なし / 未定」と「期限あり」の Home interaction にほぼそのまま使える。

ただし current `issues.tsv` admission は各 row を `DueUndetermined` として構築しており、既存 `date` column は issue の recorded-on date として使われている。そのため期限機能を実利用へ接続するには、source schema / parser / writer / TUI のどこで due date を表現するかを別 slice で設計する必要がある。

UI 初稿:

```text
Due date?
  ( ) none / undetermined
  ( ) set date   2026-08-13
```

期限が設定された open Issue は Attention の候補になる。期限なし Issue は原則 Home へ常駐させず、Issue screen では常に閲覧できる形がよい。

## Household Issue: kind vocabulary

現在の retained `issues.tsv` には `category` column があるが、admission では typed category として保持せず details text へ畳み込んでいる。

今後は、Household の感覚に近い small vocabulary を typed `IssueKind` として持つ価値があるかを検討する。

候補:

- `Want`: 欲しいもの、購入検討
- `Refund`: 返金・返金確認待ち
- `PlanDecision`: subscription 等を Plan 化、継続、停止する判断
- `Funding`: 予定支出に対して予算や資金をどう捻出するか
- `Waiting`: 回答、入金、処理など外部状態待ち
- `Review`: 後で調査・確認するもの
- `Other`: 上記に自然に入らない household matter

特に `Want` は generic な software issue vocabulary より家計簿らしく、ユーザーが「何系の matter か」を直感的に理解しやすい候補である。

ただしこの taxonomy はまだ確定しない。実際の household Issue が増える過程で、種類が自然に収束するかを観察する。

### Kind と urgency を分離する

たとえば `Want` が cyan、`Refund` が yellow のような presentation は可能だが、overdue を同じ category colour で表してはいけない。

```text
◆ Want      New chair                     Aug 13
○ Refund    Amazon refund                 Aug 11  !
◇ Plan      Continue subscription?        Aug 18
△ Funding   Find ¥8,000 for payment       Aug 15
```

`!` や強調色は期限状態、左側の symbol / label / category colour は kind を表す。

## Latest entry

Home には Journal history を何件も並べない。

最新 1 件だけ表示し、「最後に何を記録したか」を一目で確認できる checkpoint とする。

```text
Latest
  Aug 10  Coffee · ¥138 · SMBC -> Food
```

この行から Enter で transaction details へ掘れる可能性も今後検討する。

## Account balances

Home では household にとって主要な口座残高を即座に見られることを優先する。

全 account を常時表示するか、cash/bank 等の selectable subset を表示するかは未決定。account が増えても Home が report 化しないよう、information density を観察して決める。

## Navigation direction

Home 上の情報は単なる text ではなく、可能なら対象そのものを入口にする。

- Attention の Plan -> Plan detail / completion flow
- Attention の Issue -> Issue detail
- account balance -> account activity/report
- Latest -> latest transaction detail
- cycle status -> cycle report

つまり「Reports を開いてから対象を選ぶ」以外にも、見えている household object から直接掘れる navigation を目指す。

## Existing architectural direction

Interaction design と independent に、Brick adapter をひとつの巨大 Main へ集めない方針は維持する。

1. **純粋 Interaction 層** (`editor-src/`): UI に依存しない型と純粋 state transition / query
2. **画面 adapter 層** (`editor-tui-app/TUI/`): Brick rendering / event handling
3. **配線層** (`editor-tui-app/Main.hs`): global state と dispatch

ただし新しい interaction のために generic screen framework や navigation abstraction を先に作らない。実際の Home / Record / Plan / Issue flow から必要な境界を導く。

## Candidate screen families

日常 surface は概ね次の family に整理できそうだが、これは menu hierarchy を意味しない。

- **Record**: 日常記帳、multi-posting、transfer を一つの入口から扱う
- **Plans**: 予定、実績化、次回補充、編集
- **Reports**: household / account / cycle / budget の read-only view
- **Issues**: household matter の追加、確認、resolve/drop
- **Maintain**: Account、Budget、低頻度設定
- **Inspect / Recover**: diagnostics、admission failure、source inspection

Home にはこの全てを同じ強さで並べない。日常頻度の高い入口だけを前面に出す。

## Open questions

- `due soon` は何日前からか
- IssueDue の `DueUndetermined` を UI で「期限なし」と呼ぶか「未定」と呼ぶか
- Issue kind はどこまで小さく保つか。`Want` は first-class kind にするか
- source `category` を typed `IssueKind` へ移行するか、互換性をどう扱うか
- Home に表示する account は全件か selected accounts か
- cycle status の表現は `14 days remaining` だけで十分か
- Attention item に amount を出す条件
- Latest row から編集/取消へ直接行くか、detail を挟むか
- Record の account selection をどこまで検索・history-aware にするか
- transfer を Record flow から自然に導出できるか
- Home の empty state をどこまで静かにするか

## Working rule for this Draft PR

この PR は設計の器として育てる。

- conversation で固まった insight を小さく追記する
- 未決定事項を確定仕様のように書かない
- interaction と domain semantics を混同しない
- mockup は実装契約ではなく、情報構造を考える道具として扱う
- implementation change はこの Draft PR に混ぜず、設計が十分に収束してから coherent implementation PR へ切り出す
- 可愛らしさは decoration の量ではなく、意味のある記号、余白、semantic colour、静かな状態変化で作る
- exact arithmetic / identity / provenance / canonical source ownership / writer safety / fail-closed admission / multi-posting meaning を UI convenience のために弱めない

## Historical implementation sketch

以下は以前の architecture sketch から残す参考計画。現在の interaction design が固まった後、実コードの状態に合わせて再評価する。

### Phase 0: TUI モジュール分割（機能変更なし）

- `editor-tui-app/TUI/Types.hs`: `UIState`, `AppContext`, `AppWrapper` 等
- `editor-tui-app/TUI/Workspace.hs`: Workspace 描画とイベント処理
- `editor-tui-app/TUI/ActualAdd.hs`: ActualAdd 描画とイベント処理
- `editor-tui-app/TUI/Common.hs`: 真に共有される UI parts のみ
- `editor-tui-app/Main.hs`: dispatch を中心とした薄い wiring

### Phase 1: Home / navigation

旧案の generic Hub をそのまま実装するのではなく、この文書の Home projection と direct navigation を優先して再設計する。

### Phase 2: Inspect

Account / Envelope 等の connection を確認する read-only surface。

### Phase 3: Report

既存 report projection を TUI から閲覧する。

### Phase 4: Edit expansion

Actual reverse、Account maintenance など低頻度 editor operation を TUI へ接続する。

### Phase 5: polish

`?` help、key binding discovery、semantic palette、layout refinement。breadcrumb は navigation が実際に深くなった場合のみ導入を判断する。
