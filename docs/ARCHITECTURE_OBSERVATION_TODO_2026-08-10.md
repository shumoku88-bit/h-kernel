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
- [x] `HKernel.Editor.ActualWorkspace.transactionsForAccount` is explicit migration residue: its module says the Transaction-only projection remains while delivery code migrates, while current Brick and `EditorActualWorkspaceSpec` use the identity-preserving `transactionEntriesForAccount` path.
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
- [x] The narrowest ownership statement is now clear enough for a future cleanup decision: the missing shared evidence is root Journal source structure / coordinates, not Actual, Plan, Daily Target, or Budget semantics. Domain-specific metadata admission should remain with those named owners.
- [x] Preferred source-structure owner is the existing `JournalDocument`, not a new generic metadata/source framework.
  - `JournalDocument` is already documented as the pure syntax of one source document, before validation; that is exactly the layer that should know transaction headers, indented source lines, and physical coordinates.
  - enriching its private parsed transaction representation preserves the current `Journal` meaning and need not expose metadata semantics to Journal itself.
  - `Loader` currently parses a root `JournalDocument`, recursively resolves includes, flattens included blocks into one resolved document, validates it, and returns only `Journal`. Therefore root-local source evidence is discarded at the IO boundary.
  - a future implementation should preserve the original root-document evidence alongside the resolved `Journal` when source-specific admission needs it. Exact API shape remains an implementation choice; no second generic metadata abstraction is justified by current evidence.
- [x] Do not introduce a generic metadata framework merely to reduce duplication; `JournalDocument` should own structure while Actual / Plan / Daily Target continue to own metadata meaning.

### Projection / report work

- [x] Report internals already share `AccountingFacts` and several point/period/flow bases.
- [x] #135 records a real adapter-level repeated projection: Brick redraw rebuilt report projections for the same Household observation.
- [x] Core Report calculation and terminal rendering are already separate boundaries: `HKernel.Report` constructs pure report models while Render/Presentation modules own terminal output. #135 deliberately retains rendering in draw and moves only stable report-model construction to the Household observation boundary.
- [x] For one `reportBookWithPlan` request, `prepareAccountingFacts` is called once and the resulting `AccountingFacts` feeds point, period, flow, and recent-transaction bases. Equal point coordinates are shared by `preparePointPair`; compatible period/unclassified values and the shared Flow basis are also reused.
- [x] Standalone report functions (`trialBalanceAsOf`, `balanceSheetAsOf`, `profitAndLoss`, `dailyFlow`, `monthlyAccounts`, etc.) each prepare their own facts when independently requested. That is an API-boundary cost, not repeated work inside one combined ReportBook request.
- [x] Re-check of #135 while examining this overlapping TUI report boundary: PR remains open, not merged, with the same head `7b877543c84fc543d05dd81c3c15a5d979cdf9ff`; its stated scope remains retaining `ReportBook` and Household report surface with `AppContext` rather than changing report arithmetic.
- [ ] After #135 is merged or otherwise resolved, measure whether report interaction still has observable redraw cost before changing report arithmetic or caching rendered `Text`.
- [x] Current evidence does not justify a generic query-plan/cache layer: the core combined report already shares calculation facts, and the proven TUI problem is lifetime/placement of a stable projection.

### Reader-distance / vocabulary

- [x] Trace an ordinary Actual transaction from input/source to validated domain to preview to publication.
  - main path: Brick `Form ActualAddInput` -> `ActualEditIntent` -> `TransactionBlockIntent` / `IntentPosting` -> `PreparedTransactionBlock` -> `Posting` / `Transaction` -> `ActualAppendPreview` -> delivery `ActualAddPreview` -> safe writer `WriteIntent` -> whole-Household post-admission.
  - Brick Daily currently also detours through transient `ActualAddState` solely to turn the already prepared `ActualAddPreview` into `ShowingActualAddPreview` before storing its own `DailyPreview` state.
  - core convergence is good: ordinary two-posting and multi-posting inputs both become the same `ActualEditIntent` / `TransactionBlockIntent` and therefore the same validated `Transaction` construction.
  - `TransactionBlockIntent` / `PreparedTransactionBlock` add a real source-publication meaning: one source-neutral editor intent is resolved against the admitted Account registry into both a validated `Transaction` and its exact candidate block.
  - the reader-distance hotspot is mainly around delivery preview/state/writer wrappers, not `Posting` / `Transaction` itself.
- [x] Trace one outgoing Plan from source to identity/classification/report projection/completion-facing value.
  - main report path: Journal `Transaction` -> `PlanJournal` -> `IdentifiedPlanTransaction` -> `ClassifiedPlanTransaction` -> `ProjectedCommittedOutgoingPlan` -> `PaymentDirection` -> `DeclaredPaymentDirection` -> `DeclaredOutgoingPaymentDirection` + `PositiveAmount` -> `CommittedOutgoingPlan` -> `PlanFact` -> `AdmittedPlans` -> `HouseholdReportSurface`.
  - most of the long path adds distinct proof: durable Plan identity, complete multi-posting role classification, explicit binary report limitation, account declaration admission, outgoing Asset-to-Expense/Liability proof, positive amount, and committed Plan semantics.
  - `ProjectedCommittedOutgoingPlan` is especially useful evidence rather than ceremony because it retains the complete identified source transaction while admitting only the binary subset into the current narrower report type.
  - `PlanFact` is the strongest questionable adjacent wrapper: it copies source/destination Accounts back out of the already proven `CommittedOutgoingPlan` direction, and `openEligiblePlans` then rechecks those Accounts as Asset -> Expense/Liability even though `DeclaredOutgoingPaymentDirection` already proves exactly that role condition.
- [x] Trace Budget movement from source to Household policy/observation/backing.
  - main path: validated Journal `Transaction` -> `HouseholdBudgetMovement` -> `BudgetCycle` / `BudgetObservation` -> ordered `BudgetChange` / `BudgetHistory` -> `BudgetConsumption` + `BudgetEntitlement` -> `BudgetRemaining` -> `HouseholdBudgetObservation` -> `EnvelopeBacking`.
  - this path is long but overwhelmingly domain vocabulary. Each stage answers a distinct accounting/household question rather than renaming the same value.
  - `HouseholdBudgetMovement` is a narrow source-independent fact; native `budget.journal` admission verifies the binary Budget-to-Budget shape and exact opposite postings, then later policy decides what the movement means.
  - `HouseholdBudgetEvidence` is internal alignment glue for observation/policy/history; because it is private and feeds one calculation pipeline, it adds little public reader distance.
  - `HouseholdBackingPlan` is a purposeful consumer projection: Backing only needs the already-proven positive amount and destination, not the entire committed Plan.
- [x] Mark major intermediate types in the three representative paths by role.
  - **domain**: `Posting`, `Transaction`, `PlanId`, `PositiveAmount`, `PaymentDirection`, `DeclaredOutgoingPaymentDirection`, `CommittedOutgoingPlan`, `HouseholdBudgetMovement`, Budget observation/history/consumption/entitlement/remaining, `EnvelopeBacking`.
  - **evidence boundary**: `ActualJournal`, `PlanJournal`, `IdentifiedPlanTransaction`, `ClassifiedPlanTransaction`, `ProjectedCommittedOutgoingPlan`, `PreparedTransactionBlock`, `HouseholdWriteSnapshot`.
  - **projection**: `PlanFact`, `AdmittedPlans`, `HouseholdBackingPlan`, TUI workspace/open-Plan lists.
  - **adapter/ceremony**: Brick `Form`, `Name`, flow constructors, delivery preview wrappers, transient `ActualAddState` bridge.
  - **compatibility**: source-reading `buildHouseholdReportSurfaceFromPlanJournal`, old Account/Budget/DailyTarget TSV inputs, and transitional Transaction-only Actual workspace projection.
- [x] Identify adjacent values that restate already-proven meaning without adding much evidence.
  - `PlanFact` plus `openEligiblePlans` repeats outgoing role evidence already retained inside `CommittedOutgoingPlan`.
  - `ActualWorkspace.transactionsForAccount` is an older Transaction-only sibling of the identity-preserving `transactionEntriesForAccount`; current delivery/test paths inspected use the latter.
- [ ] Continue identifying other adjacent types that represent the same semantic concept without adding evidence; do not generalize from these two examples alone.
- [x] Generic/local helper names such as `mapLeft`, `singleLeft`, `tshow`, and local scan helpers are mostly private implementation vocabulary and therefore low reader-distance risk. The more important teaching-surface problem is generic public/application names that hide a domain meaning, not small local helpers.
- [x] `PlanFact` is the clearest current example of a name hiding its actual semantic role: it is not an arbitrary Plan fact, but a report/backing projection of an already committed outgoing Plan with routing Accounts copied out for later use.

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
- [x] Reverse Actual does not show the same transient state-machine duplication. `ActualReverseInput` and its parser live with the operation and Brick can use the delivery-neutral input directly; there is no parallel `ActualReverseState` workflow wrapper.
- [x] Plan Complete & Advance also has a useful delivery-neutral boundary: Brick can retain `PlanCompleteAdvanceInput` directly and `parsePlanCompleteAdvanceInput` converts it into the typed `PlanCompleteAdvanceIntent`. No second pure workflow-state machine is inserted merely to mirror Brick state.
- [x] Plan Add/Edit differ from Complete & Advance: their raw `PlanAddInput` / `PlanEditInput` and parsing live in the Brick adapter, which directly constructs editor-owned `PlanAddIntent` / `PlanEditIntent`. This avoids another interaction-state layer but makes TUI responsible for some text-to-domain conversion. Record as a boundary-style inconsistency, not yet a correctness problem.
- [x] TUI adapters do import deep domain/source modules. The strongest current example is `TUI.Model`, which imports Account declarations, Actual completion declarations, Plan journal transactions and Plan IDs to derive workspace/open-Plan lists. This is currently localized projection work rather than mutation authority, but it means `AppContext` construction is partly an application projection layer living under the Brick namespace.
- [ ] Decide later whether those stable workspace projections belong behind an application-facing vocabulary; do not move them merely to reduce imports.
- [ ] Keep UI ceremony local rather than creating a generic UI framework unless at least two stable workflows share the same meaning.

### Helpers / abstractions / compatibility

- [ ] Inventory generic helpers and polymorphic wrappers in `src`, `household-src`, `spike-src`, and `editor-src` that are used by only one semantic owner. Prefer recording concrete examples over a blanket helper hunt.
- [x] Identify current abstraction layers whose purpose is forwarding/retained compatibility rather than adding evidence, where evidence is already sufficient.
  - `ActualWorkspace.transactionsForAccount` is explicitly retained during migration to identity-preserving entries and can be treated as transition rather than domain architecture.
  - the transient Daily `ActualAddState` preview bridge mirrors Brick-owned flow rather than owning it.
  - `PlanFact` adds a projection wrapper but then enables a role recheck already proven by `CommittedOutgoingPlan`; its exact replacement still needs design care because Backing consumes routing coordinates.
- [x] Identify compatibility entry points that duplicate canonical APIs and record their remaining callers: `buildHouseholdReportSurfaceFromPlanJournal` is the clearest current case; canonical production uses `Household.Application` plus the typed admitted path, while `HouseholdReportSpec` retains the old source contract.
- [x] Review public/exposed modules against the teaching surface far enough to classify the main seam.
  - Cabal already intentionally hides several implementation kernels (`HKernel.Engine.Facts`, `HKernel.Report.Flow`, `HKernel.Report.RecentTransactions`, `HKernel.Editor.SourceAppend`, `HKernel.Spike.HouseholdConsumption`). This is evidence of deliberate API curation, not indiscriminate exposure.
  - exposed modules still combine different audiences: core domain (`Money`, `Ledger`, `Plan`), source adapters (`*.Journal`, `*.TSV`), application/config, CLI, presentation, and rendering.
  - `h-kernel-household` exposes old TSV adapters because compatibility consumers still cross the package boundary; those modules are therefore technically public without being the concepts a Haskell learner should meet first.
  - `HKernel.Spike.HouseholdReport` is the strongest exposed-surface problem because one module presents current typed production composition and historical source-reading compatibility together.
  - conclusion: do not equate Cabal `exposed-modules` with the intended educational API. A later cleanup should first define the teaching surface, then decide whether package exposure must change.
- [x] Review `h-kernel.cabal` component boundaries: the core, household, editor, and spike components express useful dependency direction, but the production application/report owner living in a component named `spike` is now semantically stale.

### Performance-sensitive repetition

- [x] Record `Journal -> AccountingFacts` preparation reachable from report requests.
  - one combined `reportBookWithPlan` prepares `AccountingFacts` exactly once and shares it across all report bases;
  - standalone report APIs prepare their own facts once per independently requested report;
  - no evidence currently supports fusing the already-shared ReportBook further.
- [x] Record source parse/admission repetition reachable from one canonical Household load/reload and the current editor publication paths; see the source-observation section above.
- [x] Record repeated Plan/completion/account list scans in currently relevant TUI/operation paths and classify frequency.
  - `makeWorkspaceContext` computes open Plans by filtering Plan transactions against completion IDs with list `notElem`, O(P × C), but only on context construction/reload, not redraw.
  - `PlanCompleteAdvance.findPlan` and `ensureOpen` are ordinary linear operation-time scans.
  - `relatedActivePlans` also uses list completion membership, but the larger structural cost for series relations is candidate-wise `sourceSeriesFor`: each candidate rebuilds `sourceBlocks` over the entire immutable Plan root.
  - current evidence therefore prioritizes shared root source observation over micro-optimizing ordinary Plan/completion lists. A `Set PlanId` may later be a small local improvement if measurement/data size justifies it.
- [x] Distinguish harmless/necessary repeated validation from suspicious whole-source repetition: writer post-admission and reload are time-separated correctness/UI observations, while `PlanCompleteAdvance` rebuilding the same immutable `planSource` once per series candidate occurs inside one pure observation and is the clearest current performance smell.
- [x] Prefer moving computation to the correct observation boundary over introducing mutable caches.

## Candidate cleanup themes, not yet approved refactors

These are hypotheses only. They become implementation TODOs only after the evidence above is checked.

- [ ] Enrich the existing `JournalDocument` root syntax observation so transaction source structure/coordinates survive long enough for domain-specific metadata admission. Preserve the unflattened root evidence across Loader admission; do not create a generic metadata framework.
- [ ] Graduate canonical Household application/report owners out of `Spike` naming/component boundaries. Evidence is now strong that current production semantics and old source compatibility are co-located.
- [ ] Reduce duplicate state/projection inside TUI observation context. Current evidence says the source-byte duplication is temporal evidence, while the more suspicious duplication is the transient single-entry `ActualAddState` bridge.
- [ ] Re-examine `PlanFact` / `openEligiblePlans`: preserve open/completed selection and report needs, but avoid copying and then re-proving outgoing Account roles if `CommittedOutgoingPlan` already carries that evidence.
- [ ] Retire `ActualWorkspace.transactionsForAccount` once any remaining non-observed caller is ruled out; current production/test paths inspected use `transactionEntriesForAccount`.
- [ ] Shrink compatibility entry points once all current callers are known. The old Household Report source-reading entrypoint now has a known compatibility-test role; old Budget TSV also has an explicit non-canonical editor CLI role.
- [ ] Define a small documented teaching surface before changing Cabal exposure; do not hide useful adapters merely because they are not first-chapter concepts.
- [ ] Simplify reader paths where adjacent types/files do not add a new invariant, evidence, or accounting meaning.

## Remote / parallel-work notes

- [x] Baseline remote checked at start of this ledger.
- [x] #135 was re-checked only when report/TUI work overlapped it; it remains open/unmerged at head `7b877543c84fc543d05dd81c3c15a5d979cdf9ff`.
- [x] #136 is the cumulative observation ledger and remains documentation-only; no implementation semantics are changed here.
- [ ] Re-check #135 again only when merging it, its head changes, or another task overlaps its two TUI files.

## Progress log

- [x] Initial cross-boundary observation recorded instead of leaving results only in chat.
- [x] Added `Account.Journal` to the source-scan inventory and recorded concrete scanner-rule divergence.
- [x] Confirmed that `Spike` currently contains production owners, not merely disposable experiments.
- [x] Completed the first Journal-root scanner inventory and classified physical-coordinate evidence versus repeated source-structure observation.
- [x] Recorded canonical Household/editor parse repetition and isolated `PlanCompleteAdvance` per-series-candidate root rescanning as the strongest current pure repeated-scan hotspot.
- [x] Established why `JournalDocument` cannot currently replace the downstream scanners: required transaction metadata/source evidence is discarded at canonical parse time.
- [x] Chose existing `JournalDocument` as the preferred structural owner rather than inventing a second generic source-observation abstraction; Loader must preserve root-local evidence if this is implemented.
- [x] Split `Spike.HouseholdReport` into its current typed production role versus its retained source-reading compatibility role, and classified current versus retired TSV source paths.
- [x] Classified Household/TUI state overlap and isolated the Daily Actual pure interaction-state bridge as a reader-distance hotspot rather than treating all copied state as duplication.
- [x] Traced representative Actual, outgoing Plan, and Budget/Backing reader paths and separated long proof/domain paths from adapter/projection repetition.
- [x] Isolated `PlanFact` role re-proof as the strongest current adjacent-type/value duplication in the report path.
- [x] Confirmed ReportBook fact/basis sharing and separated the #135 redraw-lifetime issue from report arithmetic/query-plan design.
- [x] Classified Cabal exposure versus the intended Haskell teaching surface without assuming every exposed adapter should be hidden.
- [x] Classified current list-scan costs and confirmed whole-root source rescanning is the stronger performance concern.
- [x] Recorded `ActualWorkspace.transactionsForAccount` as explicit migration residue.
- [ ] Continue from this checklist; do not restart with a blanket repository audit.
