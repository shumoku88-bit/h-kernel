# TUI HCI / Human Factors Observation 001

> **Status**: OBSERVATION / DESIGN INPUT
> **Scope**: current Brick TUI interaction, not accounting semantics
> **Purpose**: 人間工学・認知心理・HCI の観点から、h-kernel の TUI が人間へ要求している記憶、判断、移動、確認を観察する。

この文書は UI の一般則を機械的に適用するチェックリストではない。h-kernel の実際の household workflow を、**利用頻度、認知負荷、操作距離、誤操作コスト**の組み合わせとして観察するための最初の記録である。

## Research lenses

### Usability is contextual

ISO 9241-11 は usability を、特定の利用者が特定の利用状況で目的を達成するときの effectiveness / efficiency / satisfaction として扱う。

h-kernel ではこの区別が重要である。

- 毎日の Actual 記帳で 1 手増えることは大きい
- 毎月・毎期の Plan 操作は中程度の摩擦まで許容できる
- Account declaration や Settings のような低頻度 maintenance は、速度より誤りにくさを優先できる

したがって「全画面を同じ短さにする」ことは目標ではない。**頻度の高い行動ほど短く、意味の重い変更ほど慎重にする**。

Reference: ISO 9241-11:2018, Ergonomics of human-system interaction — Usability: Definitions and concepts.

### Recognition before recall

Nielsen の usability heuristics でいう recognition rather than recall は、h-kernel の Account / kind / type / report selection に直接関係する。

人間が canonical vocabulary を暗記して正確な文字列を入力するより、admitted state から見える候補を選べる方がよい。

これは domain を曖昧にすることではない。

```text
strict canonical Account identity
        ↓
visible typed candidates
        ↓
human selection
```

とすれば、厳密さを domain が所有したまま、人間から暗記責任だけを外せる。

### Direct manipulation

Shneiderman の direct manipulation は、visible object を対象として操作できることを重視する。

#163 で入った mouse navigation はこの方向に一致する。

- 見えている section tab をクリックできる
- 見えている Account / Actual / Plan / Issue row を直接選択できる
- Report / viewport を wheel で動かせる

今後も「対象を見る → 別の command vocabulary を思い出す → command を入力する」より、**見えている household object 自体を入口にする**方を優先する。

Reference: Ben Shneiderman, “Direct Manipulation: A Step Beyond Programming Languages”, IEEE Computer 16(8), 1983.

### Choice is not free

Hick / Hyman 系の choice-reaction research は、選択肢の数と不確実性が判断時間へ影響することを示す。

これは「選択肢を常に少なくしろ」という規則ではない。h-kernel では、**今その人が判断する必要のない選択肢まで同じ強さで並べない**という設計判断に使う。

たとえば Reports が 12 種存在すること自体は問題ではない。しかし Home で 12 種すべてを同列に出す必要はない。Home は頻用または現在の文脈に合う入口を見せ、完全な Report picker は一段深い場所に残せる。

References:
- W. E. Hick, “On the Rate of Gain of Information”, 1952.
- R. Hyman, choice reaction / information research, 1953.

### Pointing cost matters even in a terminal

Fitts の movement research は、対象までの距離と対象の大きさが pointing task に関係することを示す。

TUI で pixel-perfect な GUI rule をコピーする必要はないが、実務上の含意は使える。

- clickable target は 1 文字の記号だけでなく row / tab 全体にする
- scroll できる場所では対象へ repeated keypress だけで到達させない
- 頻繁な action を画面の遠い場所や深い階層へ追いやらない

Reference: Paul M. Fitts, “The Information Capacity of the Human Motor System in Controlling the Amplitude of Movement”, Journal of Experimental Psychology 47(6), 1954.

### Keyboard-complete, mouse-friendly

WCAG 2.2 は keyboard で functionality を操作できることを求める一方、mouse 等の追加 input を妨げない。

h-kernel の TUI ではこれを web-specific compliance claim としてではなく、interaction principle として借りる。

- keyboard だけで完結する
- mouse は同じ意味への別経路
- focus order は画面上の意味順と一致させる
- mouse-only action を作らない
- shortcut-only action もできるだけ避け、画面から発見可能にする

References:
- W3C Web Content Accessibility Guidelines (WCAG) 2.2, Keyboard Accessible.
- W3C Understanding Focus Order.

## Current strengths

### Daily Actual already reduces several cognitive costs

Current Daily Actual already has good HCI properties.

- Amount から focus が始まる
- Today が既定で、rare date edit は後ろにある
- typed Account candidates を admitted Accounts から出す
- recent use を candidate ranking に使う
- quantity-only input で unambiguous default Commodity を使える
- Preview を publication 前に置く

これは「毎回 domain knowledge を入力する」より、「Household がすでに知っていることを利用して人間の入力を減らす」方向である。

### Semantic write safety is visible in the interaction

Actual / Plan / Budget / Issue は candidate / preview / publication の境界を持つ。

特に #163 では mouse click を navigation / selection に留め、Plan completion、Issue close、Budget sync retry などの semantic write を click 一発で実行しない。

この区別は維持する価値が高い。

### Stable top-level sections support spatial memory

Actual / Plans / Budget / Accounts / Issues / Reports / Settings の並びが固定され、数字キーと mouse tab の二経路を持つため、利用者は位置を学習できる。

section order を文脈ごとに頻繁に並べ替えるより、安定した空間配置を維持する方がよい。

## Current friction observations

以下は correctness 問題ではない。**domain の厳密さを UI が人間の暗記や余分な判断として露出している場所**である。

### 1. Plan Add asks for too much upfront

Current Add Plan form exposes:

- Plan date
- Description
- Pay from
- Category / to
- Amount
- Commodity

すべてが最初から同じ強さで見える。

観察:

- canonical default Commodity が一意なら Commodity は通常入力から隠せる可能性がある
- Pay from / Category は free text より typed candidate selection が自然
- date default は既に作れるので、日常的には Description / Amount / accounts が中心になり得る

これは Plan domain を単純化する話ではなく、**必須の意味と、毎回人間が指定すべき意味を分ける**話である。

### 2. Account Add requires vocabulary recall

Current Account Add asks the user to type:

```text
Type: asset | liability | equity | income | expense | budget
```

これは典型的な recall burden である。

AccountType は閉じた typed vocabulary なので、UI は候補 selection を提供できる。人間が spelling を覚える必要はない。

Commodity も household defaults / existing declarations から candidate を出せる可能性がある。

### 3. Budget Movement requires exact Account names

`From Budget` / `To Budget` は canonical Budget Account を要求するが、現在は free-form field である。

Budget Account は admitted registry から有限集合として得られるため、候補を visible にする価値が高い。

この改善は validation を弱めず、むしろ invalid text を入力する経路そのものを減らす。

### 4. Issue Add exposes an unstable category as free text

Current Issue Add は `Category` を free text で受けるが、current admission は typed category として保持していない。

これは HCI と domain vocabulary の両方から不安定である。

- domain vocabulary が未確定なら、UI に category taxonomy を強く要求しない
- typed `IssueKind` が確定した後なら visible finite choice にする
- monetary Issue でない場合 Amount / Commodity は progressive disclosure の候補

つまり現時点では「分類させること」自体を first question にしない方が自然かもしれない。

### 5. Report picker is complete but flat

Current picker has 12 report choices。complete inventory としては問題ないが、頻度や目的が異なるものが同列である。

候補となる改善方向:

- last-used report を保持する
- household / accounting / history のような小さな visual grouping
- Home の visible object から relevant report へ直接入る
- full picker は網羅的な escape hatch として残す

ここで generic report taxonomy を新設する必要はない。実利用頻度を観察して grouping が本当に必要か判断する。

### 6. Plan completion may be over-expressive for the common case

Current Complete & Advance form exposes Actual date / Actual amount override / Next nominal date / Next amount override before Preview.

これは power と safety を持つが、common case が「今日、予定額どおり支払い、次回も通常どおり」なら、毎回 4 coordinates を視認・通過する必要があるかは再観察できる。

理想候補:

```text
Internet   ¥4,800

Actual: today · planned amount
Next:   normal successor

[Enter] Preview
[e] Change details
```

詳細 edit は必要なときだけ展開する。

ただし Plan completion は Actual + successor Plan + optional Budget synchronization を伴うため、routine Actual より確認を厚くする合理性は残る。

### 7. Issue close may contain redundant ceremony

Current path は概ね:

```text
select Issue
  -> Resolve / Drop choice
  -> Decision memo form
  -> Preview
  -> Publish
```

provenance を残す価値はあるが、単純な `Dropped` まで常に memo edit と preview を必要とするかは利用観察の対象になる。

可能性:

- Resolve / Drop 自体を明示選択
- memo は optional expansion
- final preview は relation / consequence がある場合に厚くする

ここでも domain event の意味は保つ。

## Interaction design rules emerging for h-kernel

### A. Domain strictness does not imply interaction strictness

```text
strict typed domain
      ≠
human must type every domain coordinate
```

UI は admitted state、defaults、history、context から候補を作ってよい。final meaning は従来どおり domain admission が決める。

### B. Optimize by frequency, not by screen symmetry

すべての画面を同じ field 数、同じ確認回数、同じ navigation depth に揃えない。

- daily record: extremely short
- Plan completion: short but explicit consequence
- maintenance: slower, safer
- recovery / source inspection: precise and technical

### C. Prefer visible objects to command vocabulary

Plan が見えているなら Plan を選ぶ。
Account が見えているなら Account を選ぶ。
Report へ行きたい reason が visible balance なら、その balance を入口にする。

command / shortcut は熟練者の accelerator であって、唯一の入口にしない。

### D. Progressive disclosure should reveal domain complexity, not hide consequences

隠してよいもの:

- unambiguous defaults
- rare overrides
- optional details
- extra postings until needed

隠してはいけないもの:

- 実際に何が記録されるか
- balance / Plan / Budget へ起きる意味ある結果
- failure / stale / recovery state

### E. One action should have one stable interaction grammar

候補となる共通 grammar:

```text
Enter   continue / preview / open selected object
Esc     cancel / one level back
Tab     next editable field
Arrows  move within the current collection
Mouse   select / navigate the same visible object
```

write confirmation key は flow ごとに増殖させず、必要な違いだけ残す。

### F. Colour carries emphasis, never sole identity

既存方針を維持する。

- selection は reverse / shape / position でも分かる
- overdue は symbol / text と色を併用
- positive / negative amount presentation は色なしでも読める
- Issue kind と urgency は別軸

## Suggested observation priorities

実装へすぐ飛ばず、次に real-terminal で次の task を実際に数回ずつ行い、操作列を記録する。

1. ordinary expense Actual
2. multi-posting purchase
3. complete-and-advance Plan
4. add a Plan
5. inspect two or three different Reports
6. add / resolve / drop an Issue
7. add an Account
8. move Budget

各 task について記録するもの:

```text
time-to-first-meaningful-action
number of decisions
number of fields touched
number of remembered strings
number of navigation steps
number of confirmations
places where current state is not visible
places where Esc / Enter meaning surprises
```

絶対的なスコアを作る必要はない。同じ task が改善前後でどう変わるかを見る。

## Tentative priority after this first audit

現時点の優先度候補は:

1. **typed candidate selection を Plan / Budget / Account maintenance へ広げ、exact name / enum recall を減らす**
2. **Plan completion の common case を progressive disclosure で短くできるか観察する**
3. **Home / direct navigation で Reports や object detail への迂回を減らす**
4. **Issue Add / Close の category・memo・confirmation ceremony を domain meaning と照らして再評価する**
5. **shortcut / Enter / Esc / focus grammar の一貫性を横断観察する**

これは implementation roadmap ではない。#160 の interaction design が育つための observation order である。

## References

- ISO 9241-11:2018, *Ergonomics of human-system interaction — Part 11: Usability: Definitions and concepts*.
- ISO 9241-112:2025, *Ergonomics of human-system interaction — Part 112: Principles for the presentation of information*.
- Jakob Nielsen, *10 Usability Heuristics for User Interface Design*.
- Ben Shneiderman, “Direct Manipulation: A Step Beyond Programming Languages”, *Computer*, 16(8), 1983, pp. 57–69.
- Paul M. Fitts, “The Information Capacity of the Human Motor System in Controlling the Amplitude of Movement”, *Journal of Experimental Psychology*, 47(6), 1954, pp. 381–391.
- W. E. Hick, “On the Rate of Gain of Information”, *Quarterly Journal of Experimental Psychology*, 4(1), 1952, pp. 11–26.
- W3C, *Web Content Accessibility Guidelines (WCAG) 2.2*, especially keyboard accessibility and focus-order guidance.

## Working rule

HCI terminologyを新しい abstraction vocabulary にしない。

`FittsLawWidget`、`CognitiveLoadManager`、generic `UsabilityAction` のような構造をコードへ作るのではなく、実際の Household interaction を観察する物差しとして使う。

**研究上の言葉は設計判断を助ける。domain vocabulary の代わりにはしない。**
