# Household TUI Interaction Design

> **Status**: DRAFT / GROWING DESIGN NOTE
> **Role**: interaction design
>
> この文書は完成仕様ではない。現在の h-kernel の実装を基準に、日常利用の導線、情報優先度、domain vocabulary と presentation の境界を育てる。

## Purpose

TUI を feature menu や screen framework から設計しない。

Household の日常行動から設計し、domain の厳密さを保ったまま、人間へ不要な分類、暗記、画面遷移を要求しない。

特に次の二つを重視する。

1. 日常記帳を一つの `Record` interaction として扱う。
2. Account selection を「検索」と「一覧」の別機能にせず、一つの discoverable chooser として扱う。

Home は依然として重要だが、最初の runtime target ではない。まず Record interaction を一貫させる。

## Current implementation baseline

この Draft の開始後、実装側はすでに進んでいる。

- section-local workspace interaction は concrete TUI owner へ戻っている。
- Multi Actual の duplicate draft ownership は解消済み。
- `ActualMultiAddInput` が authoritative draft である。
- selected posting row と unfinished posting-count text は TUI-local delivery state である。
- Account candidate preparation には recent-first ranking がある。
- Account candidate filtering には case-insensitive substring search がすでにある。
- mouse navigation / row selection は既存 TUI の複数 surface で利用できる。

したがって、古い generic Hub、module split、navigation framework、shared Form framework を未来の実装目標として復活させない。

Architecture は observed ownership から育てる。diagram の対称性や file size は owner の根拠にならない。

## Core interaction law

> **Domain は分ける。人間の行動は必要以上に分けない。**

Plan、Issue、Actual、Account、Budget はそれぞれの semantic owner を保つ。

一方、delivery interaction は domain type の列挙を最初の質問にしなくてよい。

厳密な typed domain と、毎回すべての domain coordinate を人間に入力させることは同義ではない。

```text
strict domain meaning
       !=
human must classify first
```

## Immediate runtime target: Unified Record

現在の `Expense` / `Income` / `Multi Actual` という開始時の分岐を、最終的には一つの `Record` interaction へ畳む。

概念上の最小形は:

```text
Record = Day + Description + 2 or more Postings
```

UI は最初に「支出か」「収入か」「資金移動か」「multi か」を宣言させない。

それらは admitted Accounts と postings が表す完成形の違いである。

### Two-posting expense

```text
Coffee                                      Aug 12

Account                               Amount
SMBC                                    -138
Food                                     138
                                       -----
                                           0  ✓
```

### Multi-posting purchase

同じ interaction のまま必要な row を増やす。

```text
Supermarket                                 Aug 12

Account                               Amount
SMBC                                   -2450
Food                                    1800
Household                                650
                                       -----
                                           0  ✓
```

### Income

収入も別の form family にする必要はない。

```text
Lesson payment                              Aug 12

Account                               Amount
SMBC                                    8000
Lesson income                           -8000
                                       -----
                                           0  ✓
```

複数 Accounts が一つの economic event に関係するなら、同じ Record に postings を増やせる。

### Transfer

Asset-to-Asset transfer も同じ Record の自然な完成形でよい。

```text
Move money                                  Aug 12

Account                               Amount
Yucho                                 -10000
SMBC                                   10000
                                      ------
                                           0  ✓
```

Transfer convenience を追加する場合も、`Transfer mode` を必須の最初の分岐として復活させない。

## Record identity boundary

> **one Record = one economic event**

複数 posting と複数 transaction は同じではない。

同日に独立した収入や支出が複数あった場合、それらは別々の Record として残す。

```text
morning lesson payment -> Record A
other lesson payment   -> Record B
```

unrelated events を一つの transaction に詰めるために multi-posting を使わない。

連続入力の速さが必要なら、identity を崩すのではなく `Save & next` のような interaction を後で検討する。

## Record table direction

Unified Record は row-local direct manipulation を優先する。

現在の Multi Actual にある「visible posting row を選んだ後、shared Selected Account / Selected Amount field へ移動する」間接性を減らしたい。

概念的には:

```text
Description: Supermarket

Account                               Amount
> SMBC                                 -2450
  Food                                  1800
  Household                              650
```

選択中の visible row / cell 自体が編集対象として理解できることを目指す。

Exact keyboard grammar はまだ確定しない。

候補:

- Up / Down: posting row movement
- Tab / Left / Right: Account / Amount cell movement
- Enter: chooser accept / preview depending on focus
- mouse: visible row / candidate selection
- visible add/remove-row controls: later UX evaluation

generic table framework は先に作らない。

## Account chooser: search and browse are one interaction

Account selection では二種類の利用状況を同時に満たす。

1. 名前を覚えている、または一部を覚えているので素早く検索したい。
2. 名前を忘れているので Account 一覧から発見したい。

この二つを `Search Account` / `Browse Accounts` という別モードにしない。

一つの chooser が input text に応じて自然に変わる。

```text
empty input
  -> browse admitted Accounts

text input
  -> filter the same admitted Accounts immediately
```

### Empty input

空欄では Account を発見可能にする。

```text
Account
> _

Recent
  SMBC
  Yucho
  Food

Assets
  SMBC
  Yucho

Income
  Pension
  Lesson income

Expenses
  Food
  Medical
  Household
```

Recent と typed grouping は同じ Account identity の presentation であり、新しい domain owner ではない。

### Search-as-you-type

入力文字列をそのまま query として使う。

```text
> s

SMBC
Savings
```

さらに:

```text
> sm

SMBC
```

current interaction layer にある case-insensitive substring filtering をまず利用する。

最初から generic fuzzy-search engine や scoring framework を作らない。

### Keyboard and mouse

同じ chooser を:

- text typing
- Up / Down
- Enter
- mouse row click

のどれでも扱えるようにする。

keyboard-complete を保ちつつ mouse-friendly にする。

### Raw text and admission

Account field の raw `Text` は未完成入力を正直に保持できる。

```text
"s"    -> search / unfinished input
"sm"   -> search / unfinished input
"SMBC" -> selected candidate / possible complete Account name
```

UI selector は canonical Account authority ではない。

最終的な意味と failure は downstream typed Account admission が決める。

```text
raw text
  -> visible candidates
  -> human selection
  -> existing typed admission
```

## Candidate ranking

Candidate ranking は assistance であって authority ではない。

利用可能な材料:

- recent Account use
- typed Account meaning
- current partial query
- 将来、具体的な利用証拠があれば role/context

ただし UI が transaction meaning を勝手に決めない。

たとえば最初の posting が Asset negative だから Expense を上位表示する、という ranking は将来検討できる。しかし candidate ordering が semantic classification を確定してはいけない。

## Balancing assistance

Record table には current balance を常に理解可能に表示する価値がある。

```text
Remaining: 650
```

最後の blank Amount に balancing remainder を提案する UX も候補になる。

ただし自動確定はしない。Commodity ambiguity や sign meaning がある場合に黙って補完しない。

この機能は Unified Record の最初の必須条件ではない。

## Progressive disclosure

複雑さは必要になったときだけ見せる。

隠してよいもの:

- stable Household defaults
- primary Commodity when unambiguous
- rare overrides
- extra postings until the event needs them
- optional details

隠してはいけないもの:

- 実際に publish される postings
- balance
- meaningful Plan / Budget consequences
- failure / stale / recovery state

## Primary Commodity

Household primary Commodity は common interaction を短くする default であり、domain restriction ではない。

```text
Domain
  many Commodities remain valid

Interaction
  ordinary primary Commodity may be omitted when unambiguous
```

selected Account defaults が矛盾する場合は primary Commodity で上書きせず fail closed / explicit choice とする。

## Home direction

Home は feature menu ではなく Household state の projection とする方針を維持する。

候補:

- overdue / due-soon Plan
- overdue / due-soon Issue
- cycle status
- useful Account balances
- latest entry
- direct navigation from visible Household objects
- one short `Record` entry path

ただし Home runtime implementation は Unified Record の後を優先する。

Home が先に `Expense / Income / Multi` の古い三入口を固定してしまわないようにする。

## Historical evidence and current policy

TUI convenience は temporal semantics を壊してはいけない。

> **Current policy guides current/future interpretation and decisions. Historical evidence records what was actually decided or realized at the time.**

現在の TOML policy を変えただけで過去の Household decision が別の意味に見える設計にしない。

Historical evidence、current policy、current analytical projection を区別する。

詳細は `HOUSEHOLD_HISTORY_POLICY_OBSERVATION.md` を参照する。

## Interaction priorities

現在の優先順位:

1. **Unified Record**
2. **searchable + browseable Account chooser**
3. **row-local posting editing**
4. 実使用で Record grammar を検証
5. `Save & next` / balancing suggestion 等の追加 UX
6. Home projection / direct navigation

Plan completion は common case の physical action count がすでに低いため、Record より先に keypress 削減の対象にしない。

## Completed observations

以下は以前この Draft で future work として扱っていたが、現在は実装済みまたは ownership cleanup 済みである。

- Multi Actual authoritative draft ownership
- selected posting cursor の TUI-local ownership
- section-local workspace event ownership
- concrete Plan Budget-sync picker ownership

これらを generic abstraction へ再統合しない。

## Still undecided

- exact row / cell focus grammar
- exact add / remove posting control
- whether two rows are always initially visible or the second row appears after first meaning is entered
- balancing remainder suggestion conditions
- exact recent/context candidate ranking
- whether filtered results retain AccountType groups or flatten when short
- `Save & next` grammar
- transfer conveniences that do not reintroduce a mandatory Transfer mode
- exact public Household Application operation underlying Record
- Home due-soon threshold and Account subset
- Issue lineage / source questions recorded in related observations

## Working rules

- common path stays short
- exceptional meaning branches only when needed
- strict domain ownership does not imply interaction ceremony
- visible objects beat command-vocabulary recall
- search and browse should compose instead of becoming modes
- defaults compress interaction, not semantic meaning
- no generic navigation / Form / picker / fuzzy-search framework without concrete reuse evidence
- do not split modules for symmetry or size alone
- preserve exact arithmetic, Commodity separation, identity, provenance, posting order, canonical source ownership, writer safety, fail-closed admission, stale-write rejection, recovery, and historical-evidence meaning

## Scope of PR #160

Documentation only.

Runtime Haskell changes belong in separate implementation PRs based on current `main`.