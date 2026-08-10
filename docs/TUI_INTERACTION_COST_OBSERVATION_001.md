# TUI Interaction Cost Observation 001

> **Status**: OBSERVATION / DESIGN INPUT
> **Source basis**: `main` at `6cfda06dcef01828fad3da25e35c081c87bacb2b`
> **Scope**: current Brick TUI interaction grammar after #163
> **Purpose**: 現在の household workflow が要求する操作を、実コードの event transition から数える。

この文書は stopwatch による usability test ではない。実時間、迷い、誤操作、IME の負荷は観測していない。

目的は、UI 構造そのものが何を要求しているかを比較可能にすることである。

## Counting model

### Baseline

原則として **section-local baseline** を使う。

- 対象 section はすでに開いている
- Plan / Issue / Actual reverse のような対象操作では、目的の row はすでに選択されている
- source は valid / admitted で、入力も最初から valid な common case とする

これは list length や家庭ごとの transaction 数を UI 固有コストへ混ぜないためである。

追加 navigation は別に数える。

- non-Actual section へ移動: `+1 control`（number key または mouse tab）
- visible row を mouse で直接選択: `+1 control`
- keyboard list selection: `+N controls`（現在位置からの距離）

### Unit definitions

#### `C` — control action

1 回の key press / mouse click / wheel step / explicit navigation action。

例:

- `Tab`
- `Enter`
- `Down`
- `C`
- `Y`
- mouse row click

文字列の各文字はここでは数えない。

#### `T` — text-entry act

一つの field へ一つの意味ある値を入力することを 1 act と数える。

例:

- `138`
- `Coffee`
- `expenses:food`

文字数は数えない。日本語 / 英語 / Account 名の長さの差を interaction structure に混ぜないためである。

#### `R` — recall burden

UI 上に有限の typed candidate があるのに、人間が canonical string / enum vocabulary を記憶して入力する必要がある座標の数。

新しい自由記述の description や新しい Account 名は recall とは数えない。

例:

- exact existing Account name: `R +1`
- AccountType を `asset | liability | ...` と入力: `R +1`
- known report shortcut key を思い出して直接押す: accelerator として `R +1`

`R` は時間へ換算しない。

### Advertised grammar only

この audit は画面上で現在案内されている操作 grammar を優先して数える。

たとえば Multi-posting では `Tab` forward navigation が案内されているため、未表示の reverse-focus shortcut が toolkit に存在するかもしれないことを「設計済みの近道」としては数えない。

## Summary table

| Workflow | Common-case path | C | T | R | Commit shape |
|---|---|---:|---:|---:|---|
| Ordinary Actual, recognition-first | recent-first Account candidates | 9 + candidate distance | 2 | 0 | Preview -> Publish |
| Ordinary Actual, exact-name recall | type both Account names | 7 | 4 | 2 | Preview -> Publish |
| Multi Actual, 3 postings, exact-name path | current advertised forward-Tab grammar | 18 | 7 | 3 | Preview -> Publish |
| Multi Actual, 3 postings, recognition-first | first Account candidate for each row | 21 + candidate distance | 4 | 0 | Preview -> Publish |
| Complete & Advance Plan | all suggested/default values accepted | 4 | 0 | 0 | Preview -> Confirmation -> Publish |
| Add Plan | default date + JPY retained | 6 | 4 | 2 | Preview -> Publish |
| Edit Plan | amount-only edit | 4 | 1 | 0 | Preview -> Publish |
| Reverse Actual | generated date/description retained | 3 | 0 | 0 | Preview -> Publish |
| Budget movement | default memo + JPY retained | 6 | 3 | 2 | Preview -> Publish |
| Add Account | default Expense + JPY retained | 3 | 1 | 0 | Preview -> Publish |
| Add Account | non-default AccountType | 4 | 2 | 1 | Preview -> Publish |
| Add non-monetary Issue | default `general`, no details | 4 | 1 | 0 | Preview -> Publish |
| Add monetary Issue | default `general`, no details | 6 | 3 | 1 | Preview -> Publish |
| Resolve / Drop Issue | no decision memo | 4 | 0 | 0 | Choice -> Preview -> Publish |
| Choose Report with mouse picker | visible target row | 2 | 0 | 0 | read-only open |
| Choose Report with keyboard picker | target `d` rows away | 2 + d | 0 | 0 | read-only open |
| Choose Report by remembered shortcut | known direct key | 1 | 0 | 1 | read-only switch |

These numbers are not a score. `C`, `T`, and `R` represent different kinds of cost and should not be summed into one magic usability number.

## Reconstructed flows

## 1. Ordinary Actual

Current Daily Actual starts with today already supplied and focus on Amount. Account candidates are typed and recent-first.

### Recognition-first common path

Assume both desired Accounts are the first candidate in their role.

```text
[a] open Expense                         C1
[type amount]                            T1
[Tab]                                    C2
[type description]                       T2
[Tab]                                    C3
[Down] choose first destination          C4
[Enter] accept destination               C5
[Down] choose first payment Account      C6
[Enter] accept payment Account           C7
[Enter] Preview                          C8
[Enter] Publish                          C9
```

Result:

```text
C = 9 + destination candidate distance + payment candidate distance
T = 2
R = 0
```

This is a useful tradeoff: canonical Account recall is removed, but candidate navigation adds physical actions.

### Exact-name path

```text
[a] open Expense                         C1
[type amount]                            T1
[Tab]                                    C2
[type description]                       T2
[Tab]                                    C3
[type destination Account]               T3 / R1
[Enter] accept exact Account             C4
[type payment Account]                   T4 / R2
[Enter] accept exact Account             C5
[Enter] Preview                          C6
[Enter] Publish                          C7
```

Result:

```text
C = 7
T = 4
R = 2
```

This is physically shorter but cognitively worse when exact names are not already in working memory.

### Observation

The two paths reveal a real design tradeoff rather than one universally smaller number.

A future selector can improve the TUI if it preserves `R = 0` without paying two or more extra controls per Account every time. Mouse-clickable inline candidates, search-as-filter, or a remembered context may be more valuable than merely adding more candidate rows.

## 2. Multi-posting Actual

The interaction starts with:

- today already supplied
- Description focused
- Posting count = 3
- three blank posting rows

The form order is:

```text
Date
Description
Posting count
Selected account
Selected amount
```

while Up/Down changes the selected posting row.

### Exact-name, three-posting path

Using only the currently advertised forward-Tab grammar:

```text
[m] open Multi                           C1
[type description]                       T1
[Tab] to Posting count                   C2
[Tab] to Account                         C3
[type Account row 1]                     T2 / R1
[Tab] to Amount                          C4
[type Amount row 1]                      T3
[Down] select row 2                      C5
[Tab x4] cycle back to Account           C9
[type Account row 2]                     T4 / R2
[Tab] to Amount                          C10
[type Amount row 2]                      T5
[Down] select row 3                      C11
[Tab x4] cycle back to Account           C15
[type Account row 3]                     T6 / R3
[Tab] to Amount                          C16
[type Amount row 3]                      T7
[Enter] Preview                          C17
[Enter] Publish                          C18
```

Result:

```text
C = 18
T = 7
R = 3
```

### Recognition-first path

If every desired Account happens to be the first candidate, replacing exact Account typing with `Down -> Enter` gives:

```text
C = 21 + sum(candidate distances)
T = 4   -- description + three amounts
R = 0
```

### Observation

This is the clearest physical-cost hotspot in the current daily-use surface.

The problem is not multi-posting accounting itself. The cost comes from coupling:

```text
selected posting row
      ×
shared Account/Amount form focus
```

Changing row keeps the form focused at the previous coordinate, so the user must repeatedly navigate back to Account before editing the next row.

A future unified Record interaction should aim for row-local direct manipulation, e.g.:

```text
Account                 Amount
SMBC                    -2450
Food                     1800
Household                 650
```

where selecting a visible cell/row does not require cycling through unrelated Date / Description / Posting-count fields.

This observation is much stronger than the generic statement "multi-posting has many fields". The current event grammar identifies the actual source of repeated controls.

## 3. Complete & Advance Plan

For the common case, the operation already supplies:

- Actual date = today
- Actual amount override = blank, meaning planned amount
- Next date = proposed successor date when available
- Next amount override = blank, meaning original planned amount

Therefore no text field must be touched.

```text
[Enter/C] open selected Plan              C1
[Enter] prepare Preview                   C2
[C] continue from Preview                 C3
[Y] Publish from Confirmation             C4
```

Result:

```text
C = 4
T = 0
R = 0
```

### Important correction to the first HCI audit

The current Plan Complete screen *looks* over-expressive because four editable coordinates are visible, but the common-case physical operation count is already low.

Therefore the main question is not primarily "how do we remove key presses?"

It is:

> Can the same four-action safe flow require less visual scanning and fewer apparent decisions?

Progressive disclosure may still help, but its expected benefit is cognitive/visual clarity, not necessarily a smaller `C` count.

This distinction matters.

## 4. Add Plan

Initial values:

- Plan date = tomorrow
- Commodity = `JPY`
- focus = Description

Common case keeps both defaults.

```text
[A] Add Plan                              C1
[type Description]                        T1
[Tab] to Pay from                         C2
[type exact Account]                      T2 / R1
[Tab] to Category / to                    C3
[type exact Account]                      T3 / R2
[Tab] to Amount                           C4
[type Amount]                             T4
[Enter] Preview                           C5
[Enter] Publish                           C6
```

Result:

```text
C = 6
T = 4
R = 2
```

### Observation

The strongest problem is not the six visible fields by itself. Common-case navigation already skips Date and Commodity by leaving defaults untouched.

The remaining structural cost is the two exact Account strings.

A typed Account selector can plausibly reduce `R` from 2 to 0. It should be judged against the physical-action tax observed in Daily Actual: a selector that requires repeated arrows + accept may reduce recall while increasing `C`.

## 5. Edit Plan

Amount-only edit:

```text
[E] Edit selected Plan                    C1
[Tab] to Amount override                  C2
[type amount]                             T1
[Enter] Preview                           C3
[Enter] Publish                           C4
```

Result:

```text
C = 4
T = 1
R = 0
```

Date-only edit can be `C = 3`, `T = 1` because Date starts focused.

## 6. Reverse Actual

With the intended Actual already selected, date and reverse description are generated and Description starts focused.

```text
[Enter] open Reverse                      C1
[Enter] Preview                           C2
[Enter/Y] Publish                         C3
```

Result:

```text
C = 3
T = 0
R = 0
```

This is already a very low-friction but still previewed semantic write.

## 7. Budget movement

Defaults:

- Memo = `alloc`
- Commodity = `JPY`

The current form starts at Memo.

```text
[Enter/M] open movement                   C1
[Tab] to From Budget                      C2
[type exact Budget Account]               T1 / R1
[Tab] to To Budget                        C3
[type exact Budget Account]               T2 / R2
[Tab] to Amount                           C4
[type amount]                             T3
[Enter] Preview                           C5
[Enter] Publish                           C6
```

Result:

```text
C = 6
T = 3
R = 2
```

### Observation

This is a very clean candidate for recognition-before-recall improvement because the legal Budget Accounts are finite and already admitted.

Unlike Plan completion, this is not primarily a visual-density issue. The current common path genuinely requires two exact canonical strings.

## 8. Add Account

Defaults:

- Type = `expense`
- Commodity = `JPY`

### Common Expense / JPY Account

```text
[Enter/A] Add Account                     C1
[type new Account name]                   T1
[Enter] Preview                           C2
[Enter] Publish                           C3
```

Result:

```text
C = 3
T = 1
R = 0
```

### Non-default type

```text
[Enter/A] Add Account                     C1
[type new Account name]                   T1
[Tab] to Type                             C2
[type AccountType]                        T2 / R1
[Enter] Preview                           C3
[Enter] Publish                           C4
```

Result:

```text
C = 4
T = 2
R = 1
```

### Important nuance

The first HCI audit correctly identified free-text AccountType as a recall hazard, but the operation count shows it is *not* paid in the default Expense/JPY case.

Therefore a typed selector is especially valuable for non-default Accounts, while the common expense declaration is already extremely short.

Do not make the default case longer merely to make every AccountType interaction symmetrical.

## 9. Add Issue

Defaults:

- Category = `general`
- Amount = blank
- Commodity = blank
- Details = blank

### Simple non-monetary Issue

```text
[A] Add Issue                             C1
[Tab] to Title                            C2
[type Title]                              T1
[Enter] Preview                           C3
[Enter] Publish                           C4
```

Result:

```text
C = 4
T = 1
R = 0
```

### Monetary Issue, no Details

```text
[A] Add Issue                             C1
[Tab] to Title                            C2
[type Title]                              T1
[Tab] to Amount                           C3
[type Amount]                             T2
[Tab] to Commodity                        C4
[type Commodity]                          T3 / R1
[Enter] Preview                           C5
[Enter] Publish                           C6
```

Result:

```text
C = 6
T = 3
R = 1
```

### Observation

The current simple Issue path is already short because `general` and non-monetary blanks act as defaults.

The stronger design problem is semantic: category is currently a free-text source coordinate without stable typed ownership. The operation count alone would not reveal that.

This is a useful warning against optimizing only by action count.

## 10. Resolve / Drop Issue

With the target Issue already selected and no decision memo:

```text
[Enter] Close selected Issue              C1
[R/D] choose disposition                  C2
[Enter] Preview with blank memo           C3
[Enter] Publish                           C4
```

Result:

```text
C = 4
T = 0
R = 0
```

A memo adds `T +1` but is not required by the interaction.

### Observation

The first HCI audit suspected mandatory memo ceremony. The operation trace corrects that: the memo screen exists, but blank memo can pass straight through.

The remaining question is whether a dedicated blank memo screen plus Preview earns its existence for every simple Resolve/Drop. This is a workflow-meaning question, not a text-entry burden.

## 11. Reports

From Reports section:

### Mouse picker

```text
[Enter] open picker                       C1
[click visible report row]                C2
```

Result:

```text
C = 2
T = 0
R = 0
```

### Keyboard picker

If the desired report is `d` rows from the currently selected report:

```text
C = 2 + d
T = 0
R = 0
```

### Remembered report shortcut

Many reports have direct single-key shortcuts.

```text
C = 1
T = 0
R = 1 accelerator vocabulary
```

### Observation

#163 materially changed the report cost profile.

The complete picker can remain flat without forcing repeated-key traversal because mouse direct selection is now available. Grouping may still improve comprehension, but it is no longer needed merely to solve movement cost.

The Home/direct-navigation design should therefore be justified by *task meaning and discoverability*, not by the old assumption that report selection necessarily means many Down presses.

## What the counts changed

The count audit corrects several intuitions from Observation 001.

### Stronger than expected

#### Multi-posting is the clearest interaction hotspot

It combines:

- many required semantic coordinates
- row switching
- shared field focus
- repeated forward Tab cycling
- Account recall or extra candidate navigation

This should be observed before spending effort shaving one action from already-short maintenance flows.

#### Budget movement has genuine recall cost

Two canonical Budget Account strings are required in the common case even though the candidate set is finite.

This is a strong typed-selection candidate.

### Less severe than appearance suggested

#### Plan Complete is physically short

`C = 4`, `T = 0` in the common case.

Its problem, if any, is visual/cognitive complexity and the clarity of consequences.

#### Add Account is already excellent for the default case

`C = 3`, `T = 1`, `R = 0` for a normal Expense/JPY declaration.

A universal selector redesign must not make this path worse for symmetry.

#### Simple Issue Add is already short

`C = 4`, `T = 1` with the current defaults.

Its more important unresolved question is typed Issue meaning, not raw key count.

#### Issue close does not require memo text

The blank memo screen still adds a stage, but no text-entry burden is mandatory.

## A first interaction-cost map

### Daily / high-frequency

```text
Ordinary Actual
  physical: moderate
  recall: low with candidates
  semantic gate: appropriate

Multi Actual
  physical: high
  recall: high OR physical cost even higher
  semantic gate: appropriate
```

### Periodic / medium-frequency

```text
Plan Complete
  physical: low
  recall: none
  visual/cognitive scan: potentially higher than physical count suggests

Plan Add
  physical: moderate
  recall: two canonical Accounts
```

### Maintenance / lower-frequency

```text
Budget move
  physical: moderate
  recall: two canonical Budget Accounts

Account Add default
  physical: very low
  recall: none

Issue Add simple
  physical: low
  recall: none
```

### Read-only

```text
Report switching
  mouse: low and distance-independent for visible rows
  keyboard picker: distance-dependent
  shortcut: minimal physical cost, requires learned vocabulary
```

## Design implications

### 1. Do not optimize from field count alone

Visible field count and operation count are different.

Plan Complete and Add Account demonstrate this clearly: defaults allow the user to skip visible fields without touching them.

A redesign should ask separately:

```text
physical actions?
visual scan?
choice points?
recall burden?
semantic consequences?
```

### 2. Candidate selection must be evaluated as a trade

Daily Actual shows:

```text
exact-name path
  fewer controls
  more recall

candidate path
  more controls
  less recall
```

Therefore "add a picker" is not automatically an ergonomics improvement.

The target is closer to:

> recognition without traversal tax

Possible mechanisms to observe later:

- whole-row click
- inline search/filter
- recent default with easy correction
- context-aware candidate ordering
- preserving last-used role Account where semantics permit

### 3. Multi-posting deserves row-local interaction

This is the strongest concrete result of the count audit.

The unified Record design should not merely hide the word `Multi`. It should also avoid forcing the user through a shared form focus cycle for every posting row.

### 4. Preserve cheap defaults

Several current flows are short because defaults are real interaction compression:

- today
- tomorrow for new Plan
- JPY
- Expense AccountType
- general/non-monetary Issue
- Plan amount/successor defaults

When introducing typed selectors or richer domain vocabulary, keep the valid common path at least as short unless there is a correctness reason not to.

### 5. Safety gates should be judged against semantic consequence

Ordinary Actual uses Preview -> Publish.

Plan Complete uses Preview -> Confirmation -> Publish because one action may create Actual, successor Plan, and Budget synchronization consequences.

That extra gate is not "one wasted key" merely because it increases `C`.

Operation counts identify cost; domain consequence determines whether the cost is justified.

## Next observation

The strongest next step is not another global heuristic pass.

Compare these code-derived counts with real repeated use, especially:

1. ordinary Actual
2. three-posting Actual
3. Complete & Advance Plan
4. Budget movement

For real-terminal observation, record only mismatches between the code-derived model and lived operation:

```text
- a supposedly cheap path that feels slow
- a candidate ranking that causes many extra arrows
- focus that lands somewhere surprising
- a Preview that requires rereading too much
- a shortcut that is consistently forgotten
- mouse direct manipulation that removes navigation entirely
```

Do not invent a composite UX score. The useful information is *where* the costs arise and whether the cost is justified by meaning.

## Working rule

**Count to reveal structure, not to worship small numbers.**

The shortest interaction is not automatically the best interaction. A meaningful confirmation can be worth one action; a repeated Account-name recall can be expensive despite using fewer keys.

Use counts to separate:

- necessary domain complexity
- justified safety cost
- avoidable adapter friction

and only remove the third.