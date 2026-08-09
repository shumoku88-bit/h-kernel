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
- [x] UI-independent interaction modules are a useful boundary when they keep Brick-specific state out of operation/domain owners.

### Transition / architecture-history residue

- [x] Canonical `HKernel.Household.Application` currently lives in `spike-src` and the `h-kernel-spike-household-report` component even though it now owns canonical Household admission/state.
- [x] `HKernel.Spike.HouseholdReport` contains both retained compatibility/source adapters and current typed Household report composition.
- [x] Production use of the current `Spike` component is established, so `Spike` cannot be treated as dead experimental code.
  - the main CLI imports canonical `HKernel.Household.Application`, `HKernel.Spike.HouseholdReport`, and `HKernel.Spike.HouseholdReport.Render` for Household report operation;
  - the Brick TUI imports canonical `HKernel.Household.Application`, retains `HouseholdReportSurface`, and uses `HKernel.Spike.HouseholdReport.Render`;
  - `HKernel.Household.Application` itself delegates current typed Household report composition to `HKernel.Spike.HouseholdReport`.
- [x] Current semantic ownership is clear enough for further classification without moving code: `HKernel.Household.Application` owns canonical Household admission/state; the typed calculation path in `HKernel.Spike.HouseholdReport` owns Household report composition; `Spike` is therefore partly a stale location/name, not a description of runtime status.
- [ ] Inventory retained compatibility-oriented exports inside `HKernel.Spike.HouseholdReport` and their remaining callers; in particular separate source-reading compatibility entry points from the typed `buildHouseholdReportSurfaceFromAdmitted` path.
- [ ] Inventory retained TSV compatibility paths that are still required by current canonical Household operation.

### Repeated source observation / parsing

- [x] `HKernel.Journal` already performs top-level journal block collection.
- [x] `HKernel.Account.Journal` performs an additional declaration-source shape scan before delegating declaration semantics to `HKernel.Journal`.
- [x] `HKernel.Actual.Journal` independently reconstructs transaction blocks to project Actual metadata.
- [x] `HKernel.Plan.Journal` independently reconstructs transaction blocks to project `plan-id` metadata.
- [x] `HKernel.Household.DailyTarget` independently reconstructs Plan transaction blocks for Daily Target / reservation metadata.
- [x] `HKernel.Editor.PlanCompleteAdvance` independently scans Plan source blocks for `series`, `recur`, and related metadata.
- [x] `HKernel.Editor.PlanLifecycle` independently locates physical Plan blocks / `plan-id` coordinates for edit operations.
- [ ] Record every current raw journal root scanner and the metadata/source coordinate it extracts.
- [ ] Mark which scans add genuinely new source-location evidence and which only rediscover structure already observed earlier.
- [x] Scanner rules are not fully identical across owners.
  - canonical `HKernel.Journal` ends the current block on a blank line;
  - Actual / Plan / Daily Target metadata scanners retain blank lines inside the current reconstructed block and continue until another top-level line;
  - `HKernel.Editor.PlanCompleteAdvance` follows the same continue-until-top-level shape;
  - `HKernel.Editor.PlanLifecycle` treats both `;` and `#` as comment prefixes for physical source location, while the canonical Journal and the other inspected metadata scanners use `;` comments.
  These differences do not yet prove a user-visible bug, but they are repeated evidence that source structure has more than one operational definition.
- [ ] Count repeated full-root passes in canonical Household load, report construction, Actual add, Plan add/edit/complete, Daily Target, and reload paths.
- [ ] Identify the narrowest existing representation that could carry shared source structure without stealing metadata meaning from Actual / Plan / Daily Target owners.
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
- [ ] Inventory state duplicated between `HouseholdState`, `HouseholdWriteSnapshot`, `AppContext`, operation state, and Brick forms.
- [ ] Mark cached/derived state versus independent state; derived state should not silently become a second source of truth.
- [ ] Check whether Actual daily / multi-posting / reverse flows repeat form-state machinery without a meaningful interaction distinction.
- [ ] Check whether Plan add/edit/complete flows repeat parsing or validation already owned by editor operation modules.
- [ ] Check whether TUI adapters import deep domain internals that could instead consume a smaller application-facing vocabulary.
- [ ] Keep UI ceremony local rather than creating a generic UI framework unless at least two stable workflows share the same meaning.

### Helpers / abstractions / compatibility

- [ ] Inventory generic helpers and polymorphic wrappers in `src`, `household-src`, `spike-src`, and `editor-src` that are used by only one semantic owner.
- [ ] Identify abstraction layers whose only purpose is forwarding or renaming without validation, ownership, or projection.
- [ ] Identify compatibility entry points that duplicate canonical APIs and record their remaining callers.
- [ ] Identify public exposed modules that are implementation detail rather than useful teaching/API surface.
- [ ] Review `h-kernel.cabal` exposed-module boundaries against the current domain/application architecture.

### Performance-sensitive repetition

- [ ] Record every `Journal -> AccountingFacts` preparation reachable from one report request and confirm where lazy sharing actually applies.
- [ ] Record every source parse/admission reachable from one canonical Household load/reload.
- [ ] Record repeated list scans over Plans / Actual completions / account declarations in high-frequency TUI paths.
- [ ] Distinguish harmless small pure scans from whole-source / whole-ledger repeated passes before optimizing.
- [ ] Prefer moving computation to the correct observation boundary over introducing mutable caches.

## Candidate cleanup themes, not yet approved refactors

These are hypotheses only. They become implementation TODOs only after the evidence above is checked.

- [ ] Shared journal source-structure observation with domain-specific metadata admission layered on top.
- [ ] Graduate canonical Household application/report owners out of `Spike` naming/component boundaries.
- [ ] Reduce duplicate state/projection inside TUI observation context.
- [ ] Shrink compatibility entry points once all current callers are known.
- [ ] Tighten exposed-module surface around the concepts that make h-kernel useful as a Haskell teaching example.
- [ ] Simplify reader paths where adjacent types/files do not add a new invariant, evidence, or accounting meaning.

## Remote / parallel-work notes

- [x] Baseline remote checked at start of this ledger.
- [x] #135 was open, Ready, mergeable, CI #466 SUCCESS, head `7b877543c84fc543d05dd81c3c15a5d979cdf9ff`.
- [ ] Re-check #135 only when work overlaps its two TUI files, when merging it, or when its status matters to another recorded item.

## Progress log

- [x] Initial cross-boundary observation recorded instead of leaving results only in chat.
- [x] Added `Account.Journal` to the source-scan inventory and recorded concrete scanner-rule divergence.
- [x] Confirmed that `Spike` currently contains production owners, not merely disposable experiments.
- [ ] Continue from this checklist; do not restart with a blanket repository audit.
