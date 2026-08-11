# Code Quality Cleanup Round: Fresh Audit 2026-08-11

Status: OBSERVATION ONLY
Basis: `main` at `ce225f195546c19dc0bc2b7532c168359d774f53`
Parent checklist: `CODE_QUALITY_CLEANUP_ROUND_DRAFT.md`

## Purpose

Re-audit current `main` after writing the cleanup-round checklist, without treating earlier observation branches as current truth.

Older `obs/*` branches are used only as historical evidence when current source independently points in the same direction.

This audit does not authorize implementation by itself.

## Summary

The initial hypothesis mostly survives, with important qualifications.

```text
accounting/domain core
  -> generally cohesive

largest accidental complexity
  -> delivery adapters
  -> orchestration plumbing
  -> test plumbing
  -> Cabal repetition

large module
  != defect by itself

modern Haskell
  != more extensions or abstraction
  -> fewer partial escape hatches
  -> clearer evidence ownership
  -> more linear effect/control flow where justified
```

The strongest first cleanup candidates are mechanical and adapter-local. The most architecturally interesting candidates should wait until after those reductions.

## Finding 1: Cabal test/component defaults are mechanically duplicated

Finding:
Repeated Cabal metadata is a real repository-level duplication owner.

Evidence:

- `h-kernel.cabal` is roughly 28 KB and contains many individual `test-suite` stanzas.
- Most test suites repeat:
  - `type: exitcode-stdio-1.0`
  - `hs-source-dirs: tests`
  - `default-language: GHC2024`
  - `ghc-options: -Wall -Werror=incomplete-patterns`
  - `base >= 4.14 && < 5`
- libraries and executables also repeat the language/warning defaults.
- `h-kernel-editor-actual-writer-test` currently has only `ghc-options: -Wall`, unlike most neighboring tests. This may be intentional, but the current shape makes such drift easy.
- CI actually exercises GHC 9.10.3, 9.12.4, and 9.14.1.

Owner:
Cabal/build configuration.

Why accidental / why intentional:
The repeated language edition, warnings, test source root, and test type have one reason to change. Component-specific dependency lists still carry useful architecture evidence and should remain explicit.

Candidate action:

- introduce one small `common` stanza for compiler/warning defaults;
- introduce a test default stanza for test type/source root/language/warnings where Cabal permits the result to remain obvious;
- keep each component's real `build-depends` explicit;
- review the actual-writer-test warning difference rather than silently normalizing it;
- add an explicit compiler support statement such as `tested-with` if it matches repository policy;
- review whether the declared `base` lower bound tells the truth about a package whose source edition is GHC2024.

Risk:
Low for metadata sharing, medium if support bounds are changed without checking dependency/compiler compatibility.

Qualification:
Full GHC matrix, all tests, repository audit.

Status: observed; strong early candidate.

## Finding 2: neutral test helpers are still widely duplicated

Finding:
Current tests still repeat neutral assertion/extraction helpers across many files.

Evidence:

Current-main code search finds `mustRight ::` and `assertEqual ::` definitions across many Specs. Historical measurement on an older basis found 39 `mustRight` occurrences and 38 `assertEqual` occurrences with multiple exact-body variants; current search confirms the duplication family still exists, but the old counts are not treated as current measurements.

Owner:
Test harness plumbing, not accounting/domain fixtures.

Why accidental / why intentional:
Exact identical assertion helpers have the same reason to change. Account/Plan/Journal/Budget source fixtures often explain the contract locally and should not be centralized merely to reduce lines.

Candidate action:

1. re-measure exact helper bodies on current main;
2. share only exact neutral variants that produce a net simplification after imports/Cabal declarations;
3. keep domain scenarios and source fixtures local unless a separate ownership argument exists.

A tiny `Test.Support` is plausible. A repository-wide test framework migration is not justified by this finding.

Risk:
Low if restricted to exact neutral helpers; high pedagogical/readability cost if domain fixtures are centralized indiscriminately.

Qualification:
All tests, plus spot-check that individual Specs remain understandable without following fixture indirection.

Status: observed; candidate after current-body measurement.

## Finding 3: editor CLI repeats target-path to Household-root admission and contains a production partial escape

Finding:
`editor-app/Main.hs` repeats the same adapter-level root derivation for Account, Budget Movement, and Issue commands.

Evidence:

Each path roughly performs:

```text
takeDirectory target
-> empty directory becomes "."
-> mkHouseholdRoot rootDir
-> fallback mkHouseholdRoot "."
-> error "unreachable" if that also fails
```

The production `error "unreachable"` is concentrated in this adapter path rather than in the accounting core.

Owner:
Editor CLI target-path routing/admission.

Why accidental / why intentional:
The root derivation is mechanical and has one reason to change. The domain-specific prepare/publish branches that follow it remain distinct and should not be generalized into one CRUD command engine.

Candidate action:

- introduce one small total helper for deriving/admitting the Household root associated with an explicit target path;
- return a typed/ordinary CLI failure instead of `error "unreachable"`;
- reuse it from Account, Budget, and Issue routing;
- leave each command's domain preparation explicit.

Risk:
Low, provided explicit-path CLI compatibility remains unchanged.

Qualification:
CLI contract tests plus canonical Household tests.

Status: observed; strongest small production cleanup candidate.

## Finding 4: TUI `Main` knows too much section-local interaction grammar

Finding:
The TUI shell currently centralizes section-local keyboard and mouse behavior in one broad workspace event dispatcher.

Evidence:

`handleWorkspaceEvent` currently knows about:

- section tabs;
- global quit and numeric section switching;
- report viewport scrolling and report selection;
- Budget/Accounts/Settings viewport scrolling;
- Actual account/transaction list focus, click, scroll, add/income/multi/reverse actions;
- Plan list click/scroll/add/edit/complete/Budget-sync actions;
- Issue list click/scroll/add/close actions.

File size is only corroborating evidence:

```text
editor-tui-app/Main.hs                 ~30 KB
TUI/Actual.hs                          ~44 KB
TUI/Plan.hs                            ~32 KB
TUI/Maintenance.hs                     ~28 KB
```

Owner:
TUI delivery routing.

Why accidental / why intentional:
`Main` legitimately owns top-level `UIState` transitions and global application keys. It does not obviously need to know every section's local key grammar and mouse list behavior.

Candidate action:

- keep a small global shell handler for quit/section switching/application transitions;
- delegate Workspace events according to `HouseholdSection` to concrete section owners;
- let section handlers return explicit requested transitions/actions to the shell where necessary;
- do not invent a generic navigation/event framework.

Do not split modules by line count. The goal is to reduce knowledge in the central dispatcher, not to maximize module count.

Risk:
Medium because keyboard/mouse behavior is user-facing and Brick event ordering matters.

Qualification:
Existing TUI interaction tests plus explicit keyboard/mouse characterization for preserved bindings.

Status: observed; strong ownership cleanup candidate after mechanical slices.

## Finding 5: small TUI presentation duplication is real but not yet a framework argument

Finding:
Several delivery-only shapes are duplicated across concrete TUI owners.

Evidence:

- `PreviewResult preview = PreviewRejected Text | PreviewReady preview` appears in both Plan and Maintenance TUI modules.
- `labelField :: String -> Widget Name -> Widget Name` appears in both Plan and Maintenance.
- Actual, Plan, and Maintenance each contain many hand-written `Lens'` values for Brick forms.
- list/mouse translation patterns repeat in several places.

Owner:
Brick presentation/form plumbing, if and only if the repeated behavior is truly identical.

Why accidental / why intentional:
A label row can plausibly have one presentation owner. A Plan workflow and an Issue/Budget/Account workflow do not gain a shared domain owner merely because both have input and preview screens.

Candidate action:
Review tiny extractions only after TUI routing is clearer. Prefer a two-line helper over a new generic Form DSL. Hand-written lenses may remain the clearest low-dependency choice if generation/optics infrastructure costs more than it removes.

Risk:
Low for tiny presentation helpers, high for generalized form/workflow abstractions.

Qualification:
No behavior change in rendering/focus/editing.

Status: observed; low-priority until routing ownership is clearer.

## Finding 6: canonical Household ownership is strong; its implementation is heavily hand-threaded

Finding:
`HKernel.Household.Application` has a coherent semantic owner but an orchestration shape that obscures the already-collected evidence.

Evidence:

The canonical load path roughly follows:

```text
accounts
-> Actual
-> Plan
-> Budget
-> configs/issues
-> cross-source validation
-> HouseholdState / HouseholdWriteSnapshot
```

The implementation passes an increasing collection of root texts and admitted values through `loadActual`, `loadPlan`, `loadBudget`, and `loadConfigsAndIssues`, with nested `IO` and `case` branches.

At the same time, `HouseholdWriteSnapshot` is an important correct abstraction: it seals typed Household meaning together with the exact mutable root bytes observed for coordinated writes.

Owner:
Canonical Household observation/admission.

Why accidental / why intentional:
The staged validations are intentional. The repeated argument threading and deep control-flow nesting appear incidental to how those stages are written.

Candidate action:
First prototype a private in-progress observation record or another small named evidence carrier. Evaluate whether that alone makes the pipeline linear enough. Consider `ExceptT` only if it reduces visible control-flow plumbing without hiding which stage produced which `HouseholdLoadError`.

Do not replace the sealed observation with a generic repository/session abstraction.

Risk:
Medium-high because this is a central correctness boundary.

Qualification:
Canonical Household tests, include-graph tests, writer/publication tests, and exact source-observation laws.

Status: observed; architecture cleanup candidate, not first slice.

## Finding 7: `ActualWriter` has outgrown the name `Actual`

Finding:
`HKernel.Editor.ActualWriter` is no longer merely an Actual writer owner.

Evidence:

The module owns generic writer machinery:

- `ExpectedSource`
- `CandidateSource`
- `WriteIntent`
- `WriteError`
- `WriterFileSystem`
- `publishWithAdmission`
- `publishWithPathAdmission`

It also owns source-family admission/publication helpers for Actual, Plan, and Budget journals, and is imported by multiple TUI/editor/domain-operation modules beyond Actual.

Owner:
Currently mixed: generic safe source publication plus several Journal-family admission adapters.

Why accidental / why intentional:
The implementation is not obviously duplicated or unsafe. The mismatch is semantic naming/placement: a cross-domain publication boundary lives under an Actual-specific module name because the capability grew from Actual first.

Candidate action:
Perform a focused owner audit before renaming anything:

```text
generic publication mechanism
vs
Actual source admission
vs
Plan source admission
vs
Budget source admission
```

Possible outcomes include a neutral publication owner with thin source-specific admissions, or retaining one module with a neutral name if that is the true smallest owner.

Do not split merely to create symmetry. This module is exposed through Cabal, so any rename/move has API/component consequences that must be qualified.

Risk:
Medium, mainly import/API churn rather than accounting semantics.

Qualification:
Writer law tests, all editor publication tests, Cabal/public-surface review.

Status: observed; important ownership/naming audit after lower-risk cleanup.

## Finding 8: retained Account-in-Actual compatibility is still live, not dead code

Finding:
`HKernel.Editor.ActualAccountAppend` contains both canonical `accounts.journal` append and retained inline Actual-Journal Account append behavior.

Evidence:

The module itself labels `prepareActualAccountAppend` as retained compatibility while Account ownership moves to `accounts.journal`. Current editor CLI still uses that path for an explicit Account target that is not the canonical `accounts.journal`. Tests still cover it.

Owner:
Compatibility surface during/after Account source migration.

Why accidental / why intentional:
The duplication is historical, but current direct CLI behavior still reaches it. It cannot be classified as dead from current source alone.

Candidate action:
Make an explicit compatibility decision separately:

- retain and name/document it clearly; or
- retire the explicit noncanonical path with a deliberate CLI/source-contract change.

Do not delete it as part of mechanical cleanup.

Risk:
High if removed accidentally because explicit-path workflows may depend on it.

Qualification:
CLI contract and migration/source-authority review.

Status: observed; rejected as automatic cleanup.

## Finding 9: large core modules are not automatically spaghetti

Finding:
The size hypothesis produces important counterexamples.

Evidence:

- `HKernel.Journal` is large, but its vocabulary remains tightly centered on strict Journal syntax, parser-owned coordinates, include resolution, and validation.
- `HKernel.Editor.PlanCompleteAdvance` is large, but it describes one coherent Household operation: Plan completion plus optional successor creation and coordinated publication.
- `HKernel.Render` is large but is predominantly pure terminal report rendering; any split would need a more concrete reason-to-change observation than size.

Owner:
Their existing named domains/operations.

Why accidental / why intentional:
These modules have substantial logic because their owners are substantial. Splitting them by line count would scatter vocabulary and may increase navigation cost.

Candidate action:
No size-driven split. Continue looking for duplicated authority or multiple independent reasons to change inside them.

Risk:
Unnecessary abstraction/module churn if split without owner evidence.

Qualification:
Not applicable unless a concrete later finding appears.

Status: rejected as a general cleanup rule.

## Finding 10: current partial-looking indexing is not a repository-wide modernization target

Finding:
Production code contains a few `!!` uses, but current examples do not justify a blanket ban/rewrite.

Evidence:

`HKernel.Editor.Interaction.ActualAdd` uses indexing after explicit empty-list handling or after deriving rows from a `NonEmpty` value and clamping the selected index. Other occurrences are concentrated in Plan editor paths and deserve local review, not automatic replacement.

Owner:
Local interaction/domain transformations.

Why accidental / why intentional:
Some indexing is protected by nearby invariants and can be easier to read than introducing another abstraction. The more important production partial discovered in this audit is the explicit `error "unreachable"` in CLI root plumbing.

Candidate action:
Review `!!` only when a local type can make the invariant both clearer and total. Do not create a repository law from syntax alone.

Risk:
Noise and less readable code if rewritten mechanically.

Status: rejected as a blanket modernization rule.

## Finding 11: current verification tooling is mostly evidence, not a second accounting implementation

Finding:
No fresh evidence was found that `tools/hk`, report verification scripts, or repository-audit currently reimplement the accounting kernel wholesale.

Evidence:

`tools/hk` primarily resolves the configured Household directory and routes commands to Haskell report/editor/TUI entrypoints. CI additionally checks shell/Python syntax, builds/tests the Haskell package, runs repository audit, and verifies report fixtures/corpus.

Historical HLint/Weeder/cabal-gild experiments also contain useful negative evidence:

- HLint produced context-sensitive suggestions, including some that would widen ASCII lexical contracts if applied mechanically;
- Weeder produced zero verified deletion candidates after public and test roots were accounted for in that old experiment;
- cabal-gild would have caused a near-whole-file first formatting rewrite in the observed old Cabal shape.

These older results are not current-main measurements, but they support keeping tools advisory rather than making them cleanup authority.

Owner:
Verification/delivery adapters.

Candidate action:
No new mandatory lint/formatter/dead-code tool in the first cleanup round. Prefer compiler diagnostics, current source evidence, and existing contract tests. Revisit tooling only for a concrete unresolved question.

Status: observed; no immediate implementation action.

## Priority order after fresh audit

The audit suggests the following order, deliberately starting with low-risk evidence-rich reductions.

### Round 1: mechanical repository plumbing

1. Cabal common defaults + warning/support-policy review.
2. Editor CLI root helper; remove production `error "unreachable"`.
3. Re-measure and consolidate exact neutral test helpers if the net diff is still clearly smaller.

These three should be separable PRs unless one Cabal change is strictly required to host the test helper.

### Round 2: delivery ownership

4. Reduce TUI `Main` knowledge by section-local Workspace event handling.
5. Re-evaluate tiny TUI presentation helpers after routing ownership becomes clearer.

Do not build a generic UI framework.

### Round 3: central orchestration ownership

6. Prototype a more linear private canonical Household admission pipeline while preserving `HouseholdWriteSnapshot` semantics.
7. Audit/rename/split the cross-domain safe-writer owner currently named `ActualWriter` only if the owner becomes clearer.
8. Decide retained Account-in-Actual compatibility separately rather than letting cleanup implicitly retire it.

### Round 4: repeat the audit

Run the same checklist again after the coherent cleanup slices. The second pass should explicitly compare:

- central dispatcher breadth;
- Cabal boilerplate;
- neutral test helper count;
- production partial escapes;
- source reparse/observation paths;
- writer/admission owner names;
- total module count only as context, not as a score.

## Hypothesis review

### Hypothesis 1

> The accounting/domain core is mostly cohesive; the largest accidental complexity is in adapters and orchestration.

Result: **supported so far**.

Counterevidence sought: large core modules were inspected rather than assumed bad. Journal and Plan Complete/Advance are strong size-with-cohesion counterexamples.

### Hypothesis 2

> TUI central routing can shrink without a generic navigation abstraction.

Result: **supported** by current `handleWorkspaceEvent` shape.

### Hypothesis 3

> Test support has enough mechanical duplication to justify one small shared owner.

Result: **plausible, not yet accepted**. Current duplication persists; exact-body current-main measurement is still required before implementation.

### Hypothesis 4

> Cabal common stanzas can remove substantial repetition without hiding dependencies.

Result: **strongly supported** for language/warning/test defaults. Keep component dependencies explicit.

### Hypothesis 5

> `HKernel.Household.Application` can become more linear without weakening the sealed canonical observation.

Result: **plausible, not yet proven**. The hand-threading is visible, but this is too central to refactor from aesthetics alone.

### Hypothesis 6

> Some GHC2024 cleanup remains at code-shape level even though the edition migration is complete.

Result: **supported in a narrow sense**. The clearest opportunities are totality and control-flow/owner simplification, not extension usage.

### Hypothesis 7

> Module size is a weak signal; reason-to-change and duplicated authority are stronger signals.

Result: **strongly supported**.

## Current decision

Proceed with the cleanup round, but start with the three mechanical findings before touching central architecture.

The first implementation work should make the repository easier to observe. It should not attempt to solve every finding in one branch.
