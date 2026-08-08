# h-kernel Editor 開発設計面

ステータス: アクティブな正規開発設計面  
Owner: h-kernel editor / daily Household application  
Canonical: yes  
更新日: 2026-08-09  
更新条件: editorのmain能力、writer law、TUI ownership、active roadmap順序が変わるとき

## 1. この文書の役割

この文書は、`h-kernel` editorの現在能力、守るべき設計法則、ここから完成へ進む順序を所有する。

2026-08-09の詳細な棚卸しと`bqn-ledger`比較は`CURRENT_STATE_AUDIT_2026-08-09.md`に固定する。この文書はsnapshotを繰り返さず、current targetとactive roadmapを更新し続ける。

過去のPR番号、branch、細かい実装履歴はGitが所有する。ここには現在の意味、順序、exit gateだけを置く。

## 2. Project goal

h-kernelは単に「Haskellで家計簿を実装できる」ことを目標にしない。

実用品を通して、次がコードから読めることを目標にする。

- 値が何であるか
- どの状態が不可能か
- 何と何がidentity/provenanceで関係しているか
- どこまでがpure transformationか
- どこでfilesystem/terminal/clockへ触れるか
- canonical source textとruntime projectionがどう違うか

目標形は次である。

```text
small typed domain owners
  + pure transformations
  + explicit admission
  + narrow safe effects
  + thin delivery adapters
```

Clean Architectureの語彙や抽象層を増やすこと自体は目的ではない。家計簿の意味が見えなくなるgeneric frameworkも作らない。

## 3. Canonical Household boundary

shared canonical Household rootはengine-neutralな8ファイルである。

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

```text
canonical source
  -> Haskell-specific typed admission
  -> h-kernel domain/application

canonical source
  -> BQN-specific array-native admission
  -> bqn-ledger domain/application
```

canonical sourceへHaskell constructor、Brick state、BQN rank compatibility、command-hub argument shapeを持ち込まない。

一方のengineがcanonical semanticsへ追いついていない場合、意味をsilent ignoreせずfail closedする。

### Writer authority

write capabilityとcurrent operational writer authorityを分ける。

現在明示されているcanonical writer authorityは少なくとも次である。

```text
actual.journal current writer authority = h-kernel editor
```

Account、Plan、Budget、Issueにwrite capabilityがあっても、その事実だけからprivate canonical writer authorityを移動しない。

`bqn-ledger`が同じwrite contractを実装しても、authority cutoverは別の明示chapterとする。

## 4. Current daily-use baseline

current mainでは次の高頻度operationがHousehold TUIから完結する。

1. ordinary Daily Actual
2. 3+ Posting Actual
3. selected Plan -> Actual completion
4. optional successor Plan replenishment
5. selected Actual -> Reverse
6. major Reports
7. Actual Account filtering/browsing

current TUIへ未接続の主なoperationは次である。

- Plan add
- Plan edit
- Account add
- Budget movement
- Issue add
- Issue resolve
- Issue drop

これらは「domain functionがある」だけでは完成と数えない。人間がHousehold workspaceから安全に完了できて初めてdelivery capabilityとしてcompleteとする。

## 5. Interaction law

BQN command hubをBrickへ移植しない。

Haskell TUIの基本形は、verb一覧からcommandを選ぶのではなく、現在見えているtyped対象へ自然なoperationを出すことである。

```text
Actual transaction selected
  -> Reverse

Plan selected
  -> Complete & Advance
  -> Edit

Issue selected
  -> Resolve
  -> Drop

Budget workspace
  -> Movement

Accounts workspace
  -> Add Account
```

required input contractは次を基本とする。

- Enter
- Esc
- Tab
- arrows
- ordinary text input

function key、Ctrl-modified key、prefix sequence、manual provenance identityを必須にしない。

文字shortcutは補助として存在してよいが、operationを発見する唯一の方法にしない。

### Reverse is the reference interaction

current Actual Reverseは今後のcontextual operationの参照形とする。

```text
selected admitted entity
  -> typed identity retained by workspace projection
  -> Enter
  -> operation-specific input
  -> pure validated candidate
  -> preview
  -> explicit publication
  -> fresh workspace
```

identityをdisplay text、date、description、amount、Account、whole-value equalityから復元しない。

## 6. Domain and delivery ownership

### Domain/editor owners

Domain ownerはaccounting semantics、identity、provenance、candidate preparation、admissionを所有する。

Examples:

- `HKernel.Ledger`
- `HKernel.Money`
- `HKernel.Actual.Journal`
- `HKernel.Plan.Journal`
- `HKernel.Editor.ActualAppend`
- `HKernel.Editor.ActualReverse`
- `HKernel.Editor.PlanLifecycle`
- Issue / Budget / Account named owners

### Delivery adapters

CLI/TUIは次だけを所有する。

- argv / terminal event
- cursor / focus / widget
- free-form delivery input
- explicit preview/publication choice
- effect invocation
- user-facing outcome

Delivery adapterは次を再実装しない。

- balance law
- AccountType inference
- Commodity arithmetic
- Plan recurrence semantics
- identity relation
- reversal provenance
- complete source admission
- report calculation

## 7. Writer law target

Canonical writerは最低でも次のlawを満たす。

```text
expected bytes
  -> validated complete candidate
  -> stale rejection
  -> backup
  -> sibling staged candidate
  -> immediate pre-publication stale recheck
  -> atomic publication
  -> post-admission
  -> success
     or checked restore-capable failure
```

checked restoreとは、rollback前にtargetが自分のjust-published candidateから変化していないことを確認する意味である。

cross-process distributed lock、generic transaction manager、database abstractionは導入しない。必要なのは一人のoperatorのcanonical fileを、遅延したpreviewや偶発的なparallel processから壊さない狭いlawである。

### Cross-file operations

Plan Complete & Advanceのようなtwo-source operationはfilesystem-level atomicityを主張しない。

必要なのは次である。

- both expected sources checked before first publication
- both complete candidates admitted before publication
- coordinated installation
- whole-Household post-admission
- restore both originals when the operation cannot complete
- later unrelated writerをrollbackで上書きしない

single-fileとcross-file operationは同じdomain operationではない。共通化はlawが本当に同じeffect primitiveに限る。

## 8. Roadmap ordering

ここからは次の順で進む。

```text
0. documentation baseline
1. publication correctness
2. canonical snapshot / post-admission boundary
3. TUI ownership seam
4. contextual maintenance operations
5. daily UX/report completion
6. production ownership + compatibility subtraction
7. cross-engine legacy retirement gates
```

前phaseが完全に全projectを終えるまで次へ進めない、というwaterfallではない。ただし、correctness変更、ownership refactor、UI capability追加を一つのPRへ混ぜない。

---

# Phase 0 — documentation baseline

## Goal

2026-08-09 auditを固定し、古いEditor設計面をcurrent mainへ合わせ、以降のPRが同じ優先順位を参照できるようにする。

## Scope

- current-state audit document
- this canonical roadmap update
- docs index registration

## Non-goals

- production code
- writer authority
- private source mutation
- TUI behavior

## Exit gate

- remote baselineが記録されている
- current capabilityと未接続capabilityが区別されている
- correctness / ownership / UX debtが分離されている
- next implementation chapterがPhase 1として明示されている

---

# Phase 1 — single-source publication correctness

## Goal

canonical Actual authorityを担うshared single-file publication effectのrace windowを閉じる。

## Finite slice 1A — safe publication hardening

対象はwriter effectだけ。

Implement/characterize:

- unique sibling staged candidate / recovery paths
- expected-old-bytes stale rejection before write side effects
- immediate pre-publication stale recheck
- atomic replacement
- post-publication read/admission
- rollback only if target still matches the just-published candidate
- deterministic tests for stale-before-publish and changed-before-rollback cases

Do not mix:

- TUI changes
- Account/Plan/Budget/Issue semantics
- writer-authority cutover
- source migration
- generic lock manager

## Exit gate

Every current caller of the shared single-file effect receives the stronger law without duplicating its algorithm.

---

# Phase 2 — canonical snapshot and complete post-admission

## Goal

「どのsource bytesを見てdomain判断したか」と「どのbytesをexpected-oldとしてpublishするか」を同じobservationへ結びつける。

## Finite slice 2A — application write snapshot

Introduce the narrowest useful typed snapshot that can carry:

- admitted canonical Household meaning
- exact expected bytes for the source(s) an operation may publish

The type name is not fixed by this roadmap. Do not create a generic repository/session abstraction.

The loader should prevent this shape:

```text
HouseholdState from observation A
expected raw source from observation B
```

## Finite slice 2B — Actual whole-Household post-admission

Clarify and implement the canonical success boundary for Actual publication.

Preferred law:

```text
publish Actual candidate
  -> re-admit complete canonical Household
  -> success
```

If complete Household admission fails because of the published candidate, restore the original Actual source using the checked rollback law from Phase 1.

Do not change Actual accounting/reversal semantics in this slice.

## Finite slice 2C — Plan/other publication qualification review

Review all canonical mutation routes after the common writer law is stable.

Particularly verify:

- Plan add/edit complete path-aware admission where include graphs are valid
- Plan Complete & Advance rollback guards
- Account Journal publication
- Budget Journal publication
- Issue TSV publication

Fix one source family per coherent slice when behavior differs. Do not create a universal writer framework merely to make call sites look similar.

## Exit gate

Canonical mutation routes have explicit admission scope, expected snapshot ownership, and rollback behavior.

---

# Phase 3 — thin TUI ownership seam

## Goal

Stop adding new operation controllers directly into an already responsibility-heavy `editor-tui-app/Main.hs`.

This phase is behavior-preserving ownership refactor only.

## Finite slice 3A — Actual/Plan delivery owner extraction

Use existing semantic boundaries to move delivery orchestration into small named owners.

A plausible target shape is:

```text
Main
  -> Brick app bootstrap
  -> Household section navigation/composition

TUI Actual owner
  -> Actual forms/render/event routing
  -> calls existing Actual editor operations

TUI Plan owner
  -> Plan forms/render/event routing
  -> calls existing Plan editor operations
```

Exact module names are implementation details.

Keep in Main only responsibilities that truly compose the whole application.

Do not introduce:

- generic screen framework
- generic command framework
- generic form DSL
- Lens abstraction for its own sake
- domain semantics in TUI modules

## Exit gate

Adding a new Issue/Budget/Account contextual operation no longer requires extending one monolithic top-level controller with unrelated state and effect logic.

---

# Phase 4 — contextual maintenance operations

After Phases 1-3, restore missing human capabilities in Haskell-native workspace form.

The default order is selected to maximize reuse of already existing typed semantics while keeping each slice finite.

## 4A — Issue selected -> Resolve / Drop

Why first:

- stable `IssueId` already exists
- typed `Resolved` / `Dropped` distinction exists
- identity-based close candidate already exists
- this is a clean second example of the Reverse interaction law

Target:

```text
Issues workspace
  -> select open Issue
  -> Enter
  -> Resolve or Drop
  -> decision memo
  -> preview
  -> publish
  -> fresh Issues workspace
```

No display-row index crosses the mutation boundary.

## 4B — Issue add

Expose Issue creation from the same workspace without turning Issue into accounting fact or Budget policy.

## 4C — Budget workspace -> Movement

Use the existing typed Budget movement and canonical `budget.journal` admission.

Target:

```text
Budget workspace
  -> Movement
  -> from/to Budget Accounts
  -> exact Amount
  -> preview
  -> publish
```

Do not copy BQN `budget` command argument grammar into Brick.

## 4D — Accounts workspace -> Add Account

Use `accounts.journal` as final owner of:

- Account identity
- AccountType
- optional default Commodity

Target interaction should make Account type and optional Commodity explicit without teaching the TUI canonical source syntax.

## 4E — Plan selected -> Edit

Use stable `PlanId` from the selected admitted Plan.

Do not ask the person to type PlanId or edit by list index.

Initially retain current narrow edit semantics unless a separate domain chapter deliberately broadens them.

## 4F — Plans workspace -> Add Plan

Add from the Plans workspace using typed postings and Plan metadata admission.

Do not reuse the old command-hub form merely because the CLI already has an argument grammar.

## Exit gate

The retained useful BQN maintenance accomplishments are reachable through contextual Haskell workspaces where the operation still belongs in h-kernel.

---

# Phase 5 — daily UX and Report completion

This phase improves interaction distance without adding new accounting meaning.

## 5A — ordinary-key Account discovery

Restore convenient canonical Account browsing/search after the portability cleanup.

Requirements:

- no F-key or Ctrl-key requirement
- direct text entry remains a complete fallback
- picker returns typed Account identity
- candidate list comes from canonical AccountRegistry
- terminal adapter does not infer Account meaning from names

Prefer a Tab/Enter/browse path over a new prefix mode.

## 5B — Report browse-and-Enter

Replace shortcut memorization as the only discoverable path.

Expose all retained typed reports that have stable semantics, including report distinctions already present in domain code such as Cycle Comparison when its application coordinates are available.

Letter shortcuts may remain as optional accelerators.

## 5C — Plan confirmation simplification

Re-evaluate the current Preview -> Continue -> Y sequence.

Do not remove meaningful review of a two-source operation merely to match ordinary Actual. Reduce steps only where the same validated candidate is being confirmed redundantly.

## 5D — section navigation

Evaluate whether `1-7` should remain an accelerator rather than the primary navigation contract. Prefer visible selection with ordinary keys if it reduces memorization without adding modes.

## 5E — income / transfer workflow decision

Do not automatically add dedicated screens because BQN had named commands.

First test whether ordinary/multi-posting entry already makes income and transfer clear enough. Add a dedicated workflow only when it reduces real semantic/input burden rather than duplicating `Transaction` construction.

---

# Phase 6 — production ownership and subtraction

Do this after the correctness and daily operation boundaries are stable enough that renaming/moving owners does not obscure active behavior changes.

## 6A — retire production `Spike` ownership

Move production-equivalent Household Report/Application owners to stable namespaces/source components.

This is an ownership refactor only. No Report semantic changes in the same slice.

## 6B — remove superseded compatibility APIs

Candidates include:

- Transaction-only projections superseded by identity-preserving entries
- legacy noncanonical editor fallback branches
- obsolete TUI states/shortcut descriptions
- retained adapters whose migration evidence is no longer needed

Delete only with call-site and test evidence. Do not create compatibility aliases simply to preserve internal names.

## 6C — Main.hs final audit

After contextual sections have their own natural owners, re-audit `Main.hs`.

The target is not a particular line count. The target is that Main owns application composition rather than every section's operation state machine.

---

# Phase 7 — cross-engine legacy retirement gates

h-kernel completion and bqn-ledger canonical recovery may proceed in parallel.

h-kernel Phases 1-6 do not need to wait for BQN reader parity unless a change would delete shared migration evidence or alter canonical semantics.

Private legacy sources may be deleted only after the corresponding bqn-ledger recovery gate proves:

- canonical read parity
- retained report parity where relevant
- writer capability/authority decision where relevant
- no production reader/writer/default/UI/check requires the old source

Do not delete all legacy sources in one cleanup merely because the target root is already known. Retire source-by-source according to ownership.

## 9. Priority summary

If only the next three implementation chapters are considered, the order is:

1. **Single-source safe publication hardening**
2. **Canonical write snapshot + whole-Household post-admission**
3. **Behavior-preserving TUI ownership seam**

The first new user-facing capability after these should be:

4. **Issue selected -> Resolve / Drop**

Then:

5. Issue add
6. Budget Movement
7. Account Add
8. Plan Edit
9. Plan Add
10. Account discovery / Report navigation / remaining UX subtraction

This ordering is intentional. Adding Budget/Account/Issue/Plan forms directly to current Main before writer and ownership debt are addressed would make the application more capable while making the architecture harder to teach and maintain.

## 10. Per-slice development law

Every implementation chapter starts by re-checking remote main and parallel work.

A coherent slice should have one semantic rollback boundary.

Do not mix unless inseparable:

- correctness change
- ownership refactor
- UI behavior change
- source migration
- writer authority cutover
- destructive retirement

For each slice:

1. inspect current owner and parallel branches/PRs
2. state the domain/effect phrase before editing
3. add focused synthetic evidence
4. run the relevant full test suite
5. run repository ownership audit where applicable
6. run complete report verification when report/application behavior can be affected
7. review final diff for private source leakage and compatibility growth
8. keep Draft until evidence is green
9. do not merge without explicit approval

## 11. Non-goals

- giant TUI rewrite
- BQN algorithm translation into Haskell syntax
- command-hub reimplementation
- generic repository abstraction
- giant compatibility layer
- engine-specific canonical source fields
- weakening identity/provenance for convenience
- floating-point money
- inferring identity from equality
- inferring Account policy from Account names
- deleting private legacy evidence before BQN recovery gates

## 12. Completion picture

The desired stable daily application is:

```text
HouseholdRoot
  -> one coherent admitted snapshot
  -> typed Household/domain values
  -> pure report and editor transformations
  -> narrow safe publication effects
  -> workspace delivery

workspace
  -> select meaningful entity
  -> see available domain operation
  -> enter only genuinely new information
  -> preview validated result
  -> publish safely
  -> reload one coherent Household snapshot
```

At that point、h-kernelの価値は「Haskellでも家計簿が作れた」ではなく、家計簿のidentity、relation、impossible state、pure calculation、effect boundaryがHaskellの構造として読めることにある。
