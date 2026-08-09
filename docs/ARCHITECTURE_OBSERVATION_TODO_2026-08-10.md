# h-kernel Architecture Observation TODO

Date: 2026-08-10
Baseline main: `05e5d70819a7035cda2b5cc29c1ff6030c8288e8`
Related open PR at start: #135 `perf(tui): share report projections per Household observation`

## Purpose

Keep one cumulative observation ledger so architecture work does not restart from a repository-wide audit every time.

The primary measure is not deleted lines. It is the reader distance required to understand one important accounting concept: how many names, types, files, source scans, projections, conversions, states, and adapters must be crossed before the concept becomes clear.

## Working rule

- Do not repeat a full repository audit by default.
- Re-check remote state before mutation, merge, or when parallel work may have changed the relevant boundary.
- Add evidence here when a new observation confirms, weakens, or replaces an existing hypothesis.
- Prefer checking off a recorded item over opening another broad audit.
- Refactor only after the repeated evidence and the intended semantic owner are clear.
- Preserve exact arithmetic, identity, provenance, canonical source ownership, writer safety, fail-closed admission, and multi-posting meaning.

## Classification legend

- **Domain**: an accounting or household concept worth teaching directly.
- **Boundary**: necessary separation between meanings, effects, source ownership, or validation stages.
- **Transition**: retained migration/spike/compatibility structure that may no longer describe the current architecture.
- **Duplication**: the same observation, parse, scan, projection, conversion, or decision repeated without adding a new meaning.
- **Ceremony**: framework or adapter machinery required for delivery but not part of the accounting explanation.

## Recorded observations

### Domain

- [x] `HKernel.Money` is a real domain core: `Commodity`, exact `Quantity`, single-commodity `Amount`, multi-commodity `Balance`, lawful balance composition.
- [x] `HKernel.Ledger` is a real domain core: validated `Posting` / `Transaction`, nonblank description, at least two postings, per-commodity balancing.
- [x] `HKernel.Plan` exposes meaningful staged evidence rather than arbitrary wrappers: `PaymentDirection` -> declared direction -> outgoing direction -> committed outgoing Plan.
- [x] `HKernel.Household.Policy` contains household-specific vocabulary that is meaningfully distinct from general Budget policy.
- [x] `AccountingFacts`, report bases, flow aggregation, and typed sparse `BalanceMatrix` demonstrate useful Haskell structure rather than accidental abstraction.

### Necessary boundaries

- [x] `HKernel.Journal` owns pure journal syntax and validation while `HKernel.Loader` owns filesystem/include-graph effects.
- [x] Writer stale detection / candidate publication / post-admission / rollback are real safety boundaries and must not be simplified away merely for line-count reduction.
- [x] `HouseholdWriteSnapshot` carries a real temporal invariant: admitted Household meaning and expected-old root bytes belong to the same observation.
- [x] UI-independent interaction modules are a useful boundary when they keep Brick-specific state out of operation/domain owners; individual interaction states still need evidence that a real delivery consumes them rather than reconstructing them transiently.

### Transition / architecture-history residue

- [x] Canonical `HKernel.Household.Application` currently lives in `spike-src` and the `h-kernel-spike-household-report` component even though it now owns canonical Household admission/state.
- [x] `HKernel.Spike.HouseholdReport` contains both retained compatibility/source adapters and current typed Household report composition.
- [x] Production use of the current `Spike` component is established, so `Spike` cannot be treated as dead experimental code.
  - the main CLI imports canonical `HKernel.Household.Application`, `HKernel.Spike.HouseholdReport`, and `HKernel.Spike.HouseholdReport.Render` for Household report operation;
  - the Brick TUI imports canonical `HKernel.Household.Application`, retains `HouseholdReportSurface`, and uses `HKernel.Spike.HouseholdReport.Render`;
  - `HKernel.Household.Application` itself delegates current typed Household report composition to `HKernel.Spike.HouseholdReport`.
- [x] Current semantic ownership is clear enough for further classification without moving code: `HKernel.Household.Application` owns canonical Household admission/state; the typed calculation path in `HKernel.Spike.HouseholdReport` owns Household report composition; `Spike` is therefore partly a stale location/name, not a description of runtime status.
- [x] Compatibility-oriented `HKernel.Spike.HouseholdReport` exports and current callers are classified.
  - `buildHouseholdReportSurfaceFromPlanJournal` is the old source-reading composition entry point. It accepts retained `accounts.tsv`, Budget movement TSV, Household policy text, Issue TSV, and Daily Target TSV around typed Actual/Plan journals.
  - current canonical `HKernel.Household.Application` does not call that entry point; it admits the canonical source set itself and calls `buildHouseholdReportSurfaceFromAdmitted`.
  - `tests/HouseholdReportSpec.hs` still exercises `buildHouseholdReportSurfaceFromPlanJournal` extensively, so the compatibility path remains a tested historical contract even though it is not the current canonical production composition.
  - `AdmittedPlans`, `admitPlanJournal`, `admittedOutgoingPlanValues`, `HouseholdReportSurface`, and `buildHouseholdReportSurfaceFromAdmitted` are current typed production concepts despite the `Spike` namespace.
- [x] Retained TSV compatibility paths are classified against current canonical Household operation.
  - `HKernel.Household.AccountProfile.TSV`, `HKernel.Household.BudgetMovement.TSV`, and `HKernel.Household.DailyTarget.TSV` are imported by the compatibility source-reading Household Report path, not by canonical `Household.Application` loading.
  - native canonical replacements are `accounts.journal`, `budget.journal`, and Plan-owned Daily Target/reservation metadata in `plan.journal` plus `household.toml` asset selection.
  - `HKernel.Household.Issue.TSV` is not compatibility residue: `issues.tsv` remains one of the current canonical Household sources.
  - `HKernel.Budget.TSV` is also outside the current canonical Household load path and should be treated separately as retained core compatibility rather than conflated with `issues.tsv`.
  - retained does not always mean unreachable: editor CLI still supports a non-canonical Budget movement target by parsing/publishing the old TSV path when the requested target is not canonical `budget.journal`. That is explicit compatibility behavior, not a requirement of canonical Household loading.
- [x] `HKernel.Spike.HouseholdConsumption` is marked as a temporary adapter in its own module documentation but is on the current production typed report path: `buildHouseholdReportSurfaceFromAdmitted` calls `deriveHouseholdBudgetObservation`. This is architecture-history naming/location residue, not dead code.
- [x] `h-kernel.cabal` makes the transitional packaging visible: the production `h-kernel`, editor CLI, and editor TUI depend on `h-kernel-spike-household-report`; that component exposes `HKernel.Household.Application`, `HKernel.Spike.HouseholdReport`, and its renderer while keeping `HKernel.Spike.HouseholdConsumption` internal.
- [x] `docs/HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md` is useful historical evidence but no longer describes the canonical source composition: it still records `accounts.tsv`, `budget_alloc.tsv`, and `daily_target_scope.tsv` as current Household Report inputs. Treat it as architecture-history residue until updated or superseded, not as present source authority.

### Repeated source observation / parsing

- [x] `HKernel.Journal` already performs top-level journal block collection.
- [x] `HKernel.Account.Journal` performs an additional declaration-source shape scan before delegating declaration semantics to `HKernel.Journal`.
- [x] `HKernel.Actual.Journal` independently reconstructs transaction blocks to project Actual metadata.
- [x] `HKernel.Plan.Journal` independently reconstructs transaction blocks to project `plan-id` metadata.
- [x] `HKernel.Household.DailyTarget` independently reconstructs Plan transaction blocks for Daily Target / reservation metadata.
- [x] `HKernel.Editor.PlanCompleteAdvance` independently scans Plan source blocks for `series`, `recur`, and related metadata.
- [x] `HKernel.Editor.PlanLifecycle` independently locates physical Plan blocks / `plan-id` coordinates for edit operations.
- [x] Current raw Journal-root scanner inventory and extracted evidence are recorded below.

| Owner | Root observed | Evidence extracted | Classification |
|---|---|---|---|
| `HKernel.Journal` | any Journal source | top-level syntax blocks, declarations, includes, validated transactions, posting line coordinates | necessary syntax boundary |
| `HKernel.Account.Journal` | `accounts.journal` | declaration-only source shape and account metadata gate | source-specific boundary, overlaps structural scan |
| `HKernel.Actual.Journal` | `actual.journal` root | transaction alignment plus `event-id`, `plan-id`, `reverses` line/value evidence | domain metadata projection, structural scan duplicated |
| `HKernel.Plan.Journal` | `plan.journal` root | transaction header coordinate plus `plan-id` line/value evidence | domain identity projection, structural scan duplicated |
| `HKernel.Household.DailyTarget` | `plan.journal` root | `daily-target-id`, reservation id/amount/commodity | household metadata projection, structural scan duplicated |
| `HKernel.Editor.PlanCompleteAdvance` | `plan.journal` root | arbitrary transaction metadata used for `series`, `recur`, successor metadata and relation lookup | editor/domain operation re-observation; repeated whole-root block reconstruction |
| `HKernel.Editor.PlanLifecycle` | `plan.journal` root | physical `plan-id`, transaction header, posting line and replacement coordinates | necessary physical edit evidence, though it rediscovers block structure |

- [x] Native Budget movement is a useful negative case: `HKernel.Household.BudgetMovement` consumes validated `Journal` transactions and does not rescan raw `budget.journal` blocks. `BudgetMovementAppend` similarly delegates native candidate syntax to Journal admission rather than adding another metadata block scanner.
- [x] Scans that add genuinely new source-location evidence are distinguished from scans that mainly rediscover source structure.
  - `PlanLifecycle` needs physical source coordinates because Plan Edit preserves unrelated comments/metadata while replacing exact source lines; that is a real editor boundary.
  - `Actual.Journal`, `Plan.Journal`, and `DailyTarget` add domain-specific metadata meaning, but each first rebuilds the same transaction block structure.
  - `PlanCompleteAdvance` needs `series` / `recur` meaning but does not need new physical edit coordinates; repeated `sourceBlocks` calls therefore lean more strongly toward redundant observation.
- [x] Scanner rules are not fully identical across owners.
  - canonical `HKernel.Journal` ends the current block on a blank line;
  - Actual / Plan / Daily Target metadata scanners retain blank lines inside the current reconstructed block and continue until another top-level line;
  - `HKernel.Editor.PlanCompleteAdvance` follows the same continue-until-top-level shape;
  - `HKernel.Editor.PlanLifecycle` treats both `;` and `#` as comment prefixes for physical source location, while the canonical Journal and the other inspected metadata scanners use `;` comments.
  These differences do not yet prove a user-visible bug, but they are repeated evidence that source structure has more than one operational definition.
- [x] Existing `JournalDocument` is not currently sufficient as the shared root-source observation.
  - `collectBlocks` owns canonical structural parsing, but transaction indented metadata comments are not retained in a transaction block;
  - `ParsedTransaction` retains the typed transaction and posting line coordinates, not transaction header/source metadata coordinates;
  - therefore downstream Actual / Plan / Daily Target owners cannot obtain their metadata evidence from the existing `JournalDocument` and must return to raw root `Text`.
  This explains the duplication without yet prescribing a new abstraction.
- [x] Repeated full-root work has been recorded for the currently relevant paths.
  - canonical Household load reads Journal roots once, but then performs source-family projection passes: Actual gets one additional Actual metadata scan; Plan gets one Plan metadata scan and one additional Daily Target metadata scan; native Budget movement projects from the validated Journal without another raw block scan;
  - report construction from an already admitted `HouseholdState` does not need raw source re-parsing; the observed TUI redraw repetition in #135 is projection placement, not Journal parsing;
  - `prepareActualAppendFromResolvedJournal` scans the existing Actual root once for metadata and scans the candidate Actual root again for candidate admission;
  - Plan Add from resolved Journals re-admits existing Plan metadata and Actual metadata, then admits the candidate Plan metadata;
  - Plan Edit does the same Plan/Actual re-admission, performs a separate physical Plan source-location phase, then re-admits the candidate Plan source;
  - legacy `Plan Finish` from resolved Journals admits Plan once and Actual once, then `prepareActualAppendFromResolvedJournal` admits the same existing Actual root again and the candidate Actual root once more;
  - Complete & Advance starts from typed Plan/Actual values, but reads target Plan metadata once; when a successor is requested it calls safety assessment, which reads target metadata again and, for a series relation, calls `sourceSeriesFor` once per active candidate, each rebuilding `sourceBlocks`; candidate Plan admission adds another Plan-root scan;
  - TUI publication intentionally performs time-separated post-publication admission for writer safety, then `reloadWorkspaceContext` performs another canonical Household load to obtain the fresh UI observation. These two loads have different correctness meanings and must not be labeled removable duplication merely from count alone.
- [x] The narrowest ownership statement is now clear enough for a future cleanup decision: the missing shared evidence is root Journal source structure / coordinates, not Actual, Plan, Daily Target, or Budget semantics. Domain-specific metadata admission should remain with those named owners. No implementation is approved yet.
- [ ] Decide whether canonical `HKernel.Journal` should retain enough root transaction source evidence to support those projections, or whether a separate narrowly named root-source observation type is clearer. Compare reader distance before choosing.
- [ ] Do not introduce a generic metadata framework merely to reduce duplication; require a named source-structure ownership reason first.

### Projection / report work

- [x] Report internals already share `AccountingFacts` and several point/period/flow bases.
- [x] #135 records a real adapter-level repeated projection: Brick redraw rebuilt report projections for the same Household observation.
- [ ] After #135 is merged or otherwise resolved, measure whether report interaction still has observable redraw cost before changing report arithmetic.
- [ ] Inventory other places where a stable `HouseholdState` is repeatedly projected into the same derived value within one observation.
- [ ] Separate calculation cost from terminal rendering cost before adding caches.

### Reader-distance / vocabulary

- [ ] Trace Actual transaction from source to validated domain to editor preview to publication and count distinct names/types/files crossed.
- [ ] Trace one outgoing Plan from source to identity/classification/report projection/completion and count distinct names/types/files crossed.
- [ ] Trace Budget movement from source to Household policy/observation/backing and count distinct names/types/files crossed.
- [ ] Mark every intermediate type as `domain`, `evidence boundary`, `projection`, `adapter`, `compatibility`, or `ceremony`.
- [ ] Identify names that represent the same semantic concept at adjacent layers without adding evidence.
- [ ] Identify generic/helper names that force readers away from accounting vocabulary.
- [ ] Identify domain concepts that are currently hidden behind technical names.

### Editor / state / adapters

- [x] Brick TUI contains substantial adapter ceremony (`Form`, lenses, traversals, widget names, flow states); size alone is not evidence that domain abstractions should be removed.
- [x] State overlap between `HouseholdState`, `HouseholdWriteSnapshot`, and `AppContext` is classified.
  - `HouseholdState` is the typed canonical Household meaning for one admitted observation.
  - `HouseholdWriteSnapshot` adds exact mutable root bytes to that state; those bytes are temporal writer evidence and are not a second semantic Household truth.
  - `AppContext` retains `HouseholdState`, copies the four mutable source texts from the write snapshot, and builds Brick lists plus current section/report/focus/day selections. The copied source bytes are delivery-owned expected-old evidence for preview/publication, while the lists are UI projections.
  - `reloadWorkspaceContext` rebuilds all of those projections from a fresh `HouseholdWriteSnapshot`, so current code does not independently mutate the derived transaction/Plan/Issue lists as competing domain sources.
- [x] Cached/derived versus independent state is marked for the current TUI context.
  - derived: workspace Account list, transaction list, open Plan list, Issue list; these are rebuilt from `HouseholdState`.
  - temporal evidence: actual/plan/budget/issues exact source texts retained for writer expected-old comparisons.
  - independent interaction coordinates: section, selected report, observation/entry days, workspace focus and Brick list selections.
- [x] One concrete interaction-state duplication is established in Daily Actual.
  - Brick owns `DailyInput (Form ActualAddInput ...)` / `DailyPreview ...` as its real workflow state.
  - on preview, Brick constructs `ActualAddState input EditingActualAdd`, calls `enterActualAddPreview`, immediately pattern-matches `ShowingActualAddPreview`, and converts back into Brick `DailyPreview`.
  - the editor CLI does not consume `ActualAddState`; it parses directly into operation intents. Therefore `ActualAddState` is not currently a shared production state machine between the two delivery adapters.
  - this does not yet prove the interaction module should be removed: candidate ordering/filtering and multi-posting interaction helpers are genuinely reused by Brick. It does show that the single-entry `ActualAddState` transition wrapper adds reader travel without currently carrying the Brick workflow.
- [x] Multi-posting Actual is materially different: Brick stores `ActualMultiAddState` because selection index and the editable posting collection are real interaction state, while its `MultiEditInput` Form mirrors only the currently edited row plus date/description/count for Brick text editing. This overlap has a delivery reason even if the synchronization code is ceremony.
- [ ] Check whether Reverse Actual has a similar transient pure-state wrapper or only operation + Brick state.
- [ ] Check whether Plan add/edit/complete interaction wrappers add evidence or merely bridge immediately into Brick-owned states.
- [ ] Check whether TUI adapters import deep domain internals that could instead consume a smaller application-facing vocabulary.
- [ ] Keep UI ceremony local rather than creating a generic UI framework unless at least two stable workflows share the same meaning.

### Helpers / abstractions / compatibility

- [ ] Inventory generic helpers and polymorphic wrappers in `src`, `household-src`, `spike-src`, and `editor-src` that are used by only one semantic owner.
- [ ] Identify abstraction layers whose only purpose is forwarding or renaming without validation, ownership, or projection.
- [x] Identify compatibility entry points that duplicate canonical APIs and record their remaining callers: `buildHouseholdReportSurfaceFromPlanJournal` is the clearest current case; canonical production uses `Household.Application` plus the typed admitted path, while `HouseholdReportSpec` retains the old source contract.
- [ ] Identify public exposed modules that are implementation detail rather than useful teaching/API surface.
- [x] Review the top-level `h-kernel.cabal` component boundary far enough to establish that production executables depend on a component still named `h-kernel-spike-household-report`; the finer exposed-module teaching/API review remains open below.

### Performance-sensitive repetition

- [ ] Record every `Journal -> AccountingFacts` preparation reachable from one report request and confirm where lazy sharing actually applies.
- [x] Record source parse/admission repetition reachable from one canonical Household load/reload and the current editor publication paths; see the source-observation section above.
- [ ] Record repeated list scans over Plans / Actual completions / account declarations in high-frequency TUI paths.
- [x] `makeWorkspaceContext` computes open Plans by `filter` plus `notElem` against a list of closed PlanIds, so rebuild cost is O(open-plan-candidates × completion-declarations). It runs on context construction/reload, not on every redraw; record it as a possible scale hotspot, not a current optimization target without measurement.
- [x] Distinguish harmless/necessary repeated validation from suspicious whole-source repetition: writer post-admission and reload are time-separated correctness/UI observations, while `PlanCompleteAdvance` rebuilding the same immutable `planSource` once per series candidate occurs inside one pure observation and is the clearest current performance smell.
- [x] Prefer moving computation to the correct observation boundary over introducing mutable caches.

## Candidate cleanup themes, not yet approved refactors

These are hypotheses only. They become implementation TODOs only after the evidence above is checked.

- [ ] Shared Journal root source-structure observation with domain-specific metadata admission layered on top. Evidence is now strong; exact owner/type shape still undecided.
- [ ] Graduate canonical Household application/report owners out of `Spike` naming/component boundaries. Evidence is now strong that current production semantics and old source compatibility are co-located.
- [ ] Reduce duplicate state/projection inside TUI observation context. Current evidence says the source-byte duplication is temporal evidence, while the more suspicious duplication is the transient single-entry `ActualAddState` bridge.
- [ ] Shrink compatibility entry points once all current callers are known. The old Household Report source-reading entrypoint now has a known compatibility-test role; old Budget TSV also has an explicit non-canonical editor CLI role.
- [ ] Tighten exposed-module surface around the concepts that make h-kernel useful as a Haskell teaching example.
- [ ] Simplify reader paths where adjacent types/files do not add a new invariant, evidence, or accounting meaning.

## Remote / parallel-work notes

- [x] Baseline remote checked at start of this ledger.
- [x] #135 was open, Ready, mergeable, CI #466 SUCCESS, head `7b877543c84fc543d05dd81c3c15a5d979cdf9ff`.
- [x] #136 is the cumulative observation ledger and remains documentation-only; no implementation semantics are changed here.
- [ ] Re-check #135 only when work overlaps its two TUI files, when merging it, or when its status matters to another recorded item.

## Progress log

- [x] Initial cross-boundary observation recorded instead of leaving results only in chat.
- [x] Added `Account.Journal` to the source-scan inventory and recorded concrete scanner-rule divergence.
- [x] Confirmed that `Spike` currently contains production owners, not merely disposable experiments.
- [x] Completed the first Journal-root scanner inventory and classified physical-coordinate evidence versus repeated source-structure observation.
- [x] Recorded canonical Household/editor parse repetition and isolated `PlanCompleteAdvance` per-series-candidate root rescanning as the strongest current pure repeated-scan hotspot.
- [x] Established why `JournalDocument` cannot currently replace the downstream scanners: required transaction metadata/source evidence is discarded at canonical parse time.
- [x] Split `Spike.HouseholdReport` into its current typed production role versus its retained source-reading compatibility role, and classified current versus retired TSV source paths.
- [x] Classified Household/TUI state overlap and isolated the Daily Actual pure interaction-state bridge as a reader-distance hotspot rather than treating all copied state as duplication.
- [ ] Continue from this checklist; do not restart with a blanket repository audit.
