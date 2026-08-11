# Repository-wide Code Quality Cleanup Round

Status: DRAFT / observation and cleanup planning
Date: 2026-08-11
Scope: repository-wide code-quality review before another implementation wave

## Purpose

h-kernel has reached a point where the core accounting, source admission, writer safety, Plan lifecycle, reports, and daily-use TUI are substantial enough that local feature work can hide structural repetition around them.

This round pauses feature-driven cleanup and asks a different question:

> Which parts of the repository are carrying accidental duplication, hand-written plumbing, oversized orchestration, stale build structure, or delivery-layer tangling that can be removed without weakening domain ownership?

The goal is not to make the repository look abstract, small, fashionable, or maximally DRY. The goal is to make the existing meaning easier to see and harder to accidentally duplicate.

## Non-goals

This Draft does not authorize:

- redesigning Money, Ledger, Journal, Plan, Budget, Issue, or Household semantics;
- replacing named domain types with generic frameworks;
- splitting modules only because they are large;
- merging two workflows merely because their forms look similar;
- introducing an application framework, generic event bus, generic navigation engine, or universal editor state;
- adopting Hspec, Tasty, lens, effect systems, optics, mtl stacks, or another dependency merely because it is common in modern Haskell;
- rewriting working code only to use newer syntax or extensions;
- changing canonical source formats or writer authority;
- weakening exact arithmetic, identity, provenance, stale-write rejection, post-admission, or fail-closed behavior.

A cleanup is justified only when it removes accidental structure while preserving or clarifying the real owner.

## Guardrail: shared code is not automatically better code

Use this test before introducing a shared helper or abstraction:

```text
same shape
+ same semantic owner
+ same reason to change
-> sharing is a candidate

same shape
+ different owner or different reason to change
-> duplication may be correct
```

Examples:

- a test `mustRight` helper has no accounting owner and can usually be shared;
- repeated Cabal warning/default-language stanzas are build configuration and can usually be shared;
- a Brick field-row presentation helper may be shared if it owns presentation only;
- Actual and Plan preview states should not become one generic domain workflow merely because both have an input/preview screen;
- Account, Budget, and Issue maintenance should not be forced into one generic CRUD abstraction if their admission/publication meanings differ.

Prefer a small duplicate over a false owner.

## Initial observations, not conclusions

The following are starting witnesses from current `main`. They must be re-audited before implementation work.

### TUI orchestration

Current TUI production files include approximately:

```text
editor-tui-app/Main.hs                         ~30 KB
HKernel/Editor/TUI/Actual.hs                  ~44 KB
HKernel/Editor/TUI/Plan.hs                    ~32 KB
HKernel/Editor/TUI/Maintenance.hs             ~28 KB
```

File size alone is not a defect. The concrete concern is that `Main.hs` currently routes global keys, section keys, list navigation, mouse scrolling, row selection, transitions, report selection, and publication requests through a broad central event shape.

Audit whether:

- global application events and section-local events are mixed unnecessarily;
- each `HouseholdSection` could own its delivery event handling without inventing a generic navigation framework;
- `Main` can become wiring while Actual/Plan/Budget/Accounts/Issues/Reports retain their concrete semantics;
- duplicated list/mouse plumbing has one genuine delivery owner;
- existing TUI state contains any remaining duplicate authority after the Multi Actual cleanup.

Do not split `Maintenance.hs`, `Actual.hs`, or `Plan.hs` by line count. Split only where one concrete owner or interaction boundary becomes clearer.

### TUI presentation duplication

Current witnesses include repeated small shapes such as:

- local `PreviewResult` types;
- similar `labelField` layout helpers;
- many hand-written Brick `Lens'` values for text fields;
- repeated list movement / mouse wheel translation;
- repeated publish/reload/result presentation patterns.

Audit each witness separately.

Possible outcomes include:

```text
keep duplicate
extract tiny presentation helper
move helper to existing owner
delete obsolete helper
simplify state so helper disappears
```

Do not create a generic Form DSL unless repeated evidence proves that a DSL is the real owner.

### Household application orchestration

`HKernel.Household.Application` deliberately owns canonical Household admission and currently preserves an important single-observation contract. That ownership is valuable.

Its implementation, however, contains a long staged IO pipeline roughly shaped as:

```text
load accounts
-> load Actual
-> load Plan
-> load Budget
-> load configs/issues
-> validate cross-source agreement
-> assemble HouseholdState / HouseholdWriteSnapshot
```

The current implementation passes an increasing set of already-admitted values and exact root source texts through nested functions and nested `case` expressions.

Audit whether the code can become more linear without changing the ownership contract. Candidate techniques may include:

- a small private intermediate record representing the in-progress canonical observation;
- `ExceptT` or another existing-base-compatible control-flow simplification if it materially improves readability;
- small admission steps returning named evidence;
- removing argument threading that exists only because earlier stages have no private aggregate.

None of those techniques is a predetermined solution. In particular, do not introduce an effect stack merely to look modern.

### Test support

The repository has broad test coverage across accounting laws, Journal admission, Household policy, writers, canonical Household loading, Plan lifecycle, TUI interaction, reports, CLI contracts, corpus verification, and repository audit.

The concern is not lack of tests. It is repeated test plumbing.

Audit:

- repeated `assertEqual`, `assertTrue`, `mustRight`, `mustJust`, `expectLeft`, temporary-directory helpers, fixture builders, account/commodity constructors, and source snippets;
- whether repeated fixture construction encodes domain meaning that should remain test-local;
- whether one small `TestSupport` module would remove noise without hiding test intent;
- whether giant individual specs contain separable law/contract groups;
- whether tests duplicate production parsing merely to construct values;
- whether property tests should replace families of hand-enumerated examples where a real law exists;
- whether golden/corpus tests and unit tests overlap intentionally or accidentally.

Do not migrate test frameworks by default. A test framework change needs an independent benefit beyond removing a few helper functions.

### Cabal structure

The root Cabal file contains multiple libraries, executables, and many test suites. Current components already use `default-language: GHC2024`, but component/test declarations repeat warning options, language edition, source directories, and common dependencies extensively.

Audit:

- Cabal `common` stanzas for warnings and test defaults;
- whether repeated dependency declarations can be reduced without making component dependencies implicit or dishonest;
- whether supported GHC policy matches declared `base` bounds;
- whether `tested-with` should record the actual supported compiler matrix;
- whether component boundaries still reflect real dependency boundaries;
- whether any exposed module is exposed only because tests or another local component need it;
- whether tools belong in the root package or remain better isolated;
- whether the Cabal file can become shorter while making component ownership more obvious.

Do not optimize for minimum line count. Explicit component dependencies are useful evidence.

### GHC2024 and Haskell style

The migration to GHC2024 is complete enough that the question is no longer whether the edition is enabled. The audit should instead ask whether older hand-written structure remains where the current language/library baseline offers a simpler expression.

Look for:

- deeply nested `case` pyramids;
- avoidable manual state threading;
- repeated newtype-like validation performed as raw `Text` in production rather than at a named admission boundary;
- partial-looking helper patterns that can become total through existing types;
- ad-hoc tuples where a local named type would clarify ownership;
- unnecessary compatibility wrappers left after migrations;
- redundant imports/extensions and warning suppressions;
- manual recursion/folds that obscure a standard combinator without adding domain meaning;
- old API compatibility that no current caller needs.

Do not chase syntax novelty. Newer Haskell is useful only when it makes domain meaning or effects more explicit.

### Production module shape

Large current production modules include Journal, Render, Report, Household Application, Plan completion/editor paths, and several TUI owners.

Audit size together with cohesion:

```text
large + one owner + one vocabulary
-> may be healthy

large + multiple reasons to change
-> split candidate

small + forwarding only + no independent invariant
-> deletion/merge candidate
```

Look especially for:

- forwarding/alias modules left by prior migrations;
- production helpers with one caller but no independent invariant;
- parallel implementations of the same source admission or publication rule;
- read paths that reparse source already owned by `HouseholdState` / snapshot;
- report projections or render layers that recompute already-prepared meaning;
- public APIs whose only purpose is historical compatibility.

### Scripts, verification, and repository tooling

The repository also contains shell and Python verification entrypoints. They are legitimate delivery/verification adapters, but should not become a second implementation of accounting or routing semantics.

Audit:

- duplicated command routing between `tools/hk`, Haskell CLI modules, and verification scripts;
- report command inventories encoded in more than one place;
- Python/shell code that parses business meaning rather than verifies output/contracts;
- repeated fixture/path discovery;
- stale migration or observation tooling that can be retired.

## The cleanup round

Run the audit in the following passes. Findings should be recorded before broad refactors begin.

### Pass A: inventory and mechanical duplication

Inventory current modules/components/tests/tools and collect concrete repetitions.

Classify each repetition as:

```text
presentation plumbing
build plumbing
test plumbing
orchestration plumbing
domain meaning
intentional boundary duplication
unknown
```

Only the first four are presumptive cleanup candidates.

### Pass B: ownership and dependency direction

For each candidate ask:

1. Who owns this meaning?
2. Which component should know it?
3. Is the current dependency direction consistent with that owner?
4. Would extraction create a new owner that exists only to host shared code?
5. Can deletion or direct use of an existing owner solve it instead?

Prefer deletion and existing owners over new `Common`, `Utils`, `Framework`, or `Shared` modules.

### Pass C: control flow and state authority

Trace:

```text
source observation
-> admission
-> domain value
-> projection / interaction draft
-> preview
-> publication
-> reload
```

Search for duplicated authority, reparse/reload loops, temporary mirrored state, and nested control flow that hides which evidence is already available.

### Pass D: tests and Cabal

Treat tests and build metadata as production-quality repository code.

Produce concrete proposals for:

- test helper consolidation;
- property/law opportunities;
- test-suite grouping only where useful;
- Cabal common stanzas;
- compiler/base support policy;
- exposed/private module corrections.

### Pass E: GHC2024-native simplification

Review representative modules from core, Household, Editor, TUI, tests, and tooling.

Record places where the current edition/baseline can remove plumbing. Every proposal must state the semantic improvement, not merely the language feature used.

### Pass F: re-audit after cleanup

After coherent cleanup PRs land, run the same inventory again.

Success is not measured only by deleted lines. Look for:

- fewer duplicated owners;
- shorter dependency paths;
- fewer raw reparses and mirrored states;
- smaller central dispatch points;
- less repeated test/build boilerplate;
- unchanged or stronger domain vocabulary;
- unchanged writer/source correctness;
- easier identification of where a future feature belongs.

## Finding format

Record findings in this Draft or follow-up observation PRs using a compact shape:

```text
Finding:
Evidence:
Owner:
Why accidental / why intentional:
Candidate action:
Risk:
Qualification:
Status: observed | rejected | accepted | implemented
```

A finding can be explicitly rejected. Rejection is useful when a repeated shape is actually protecting distinct domain ownership.

## Qualification baseline

Every implementation slice from this cleanup round must preserve, where applicable:

- exact decimal Quantity semantics;
- no implicit cross-Commodity arithmetic;
- validated Account / Transaction / Plan identities;
- provenance and reversal/completion lineage;
- canonical Household source ownership;
- expected-old / stale-write rejection;
- preview before publication where currently required;
- backup / atomic publication / post-admission / recovery behavior;
- include-graph meaning;
- multi-posting meaning and ordering;
- current policy versus historical evidence distinction;
- existing CLI/TUI user-visible behavior unless a separate UX change explicitly authorizes a change.

Baseline verification remains:

```bash
cabal build all
cabal test all
cabal run exe:repository-audit
```

Report-affecting changes additionally use the existing report verification contract.

## Starting hypotheses to challenge

The next audit should attempt to disprove these, not assume them:

1. The accounting/domain core is mostly cohesive; the largest accidental complexity is in adapters and orchestration.
2. TUI central routing can shrink without a generic navigation abstraction.
3. Test support has enough mechanical duplication to justify one small shared owner.
4. Cabal common stanzas can remove substantial repetition without hiding dependencies.
5. `HKernel.Household.Application` can become more linear without weakening the sealed canonical observation.
6. Some GHC2024 cleanup remains at the code-shape level even though the edition migration itself is complete.
7. Module size is a weak signal; reason-to-change and duplicated authority are stronger signals.

The audit is complete only after these hypotheses have been checked against the full repository and counterexamples have been recorded.

## Decision

Do one repository-wide quality pass before using local cleanup observations as implementation instructions.

Observe first, classify ownership second, then implement coherent reductions. Do not turn DRY, module count, modern syntax, or line-count reduction into architecture goals.
