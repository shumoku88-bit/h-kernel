# Public Module Surface Observation 001

> **Status**: OBSERVATION ONLY  
> **Observed basis**: repository main `b5c129ca199db23f0a84a0c7e011a43f1f903a71`, with tooling-observation documentation stacked through #173  
> **Question**: Is the Cabal `exposed-modules` surface itself a good map for learning h-kernel?

## Why observe this

The first Weeder subtraction audit preserved all Cabal `exposed-modules` as roots before drawing deletion conclusions. That was necessary for safe reachability analysis, but it did not prove that every exposed module has the same public or teaching role.

h-kernel is both a real Household application and a Haskell teaching surface. The repository policy therefore asks for Haskell meaning, domain ownership, effect boundaries and named transformations to be visible from the code itself.

This observation asks a narrower architecture question:

> Does Cabal visibility already express the intended teaching surface, or is it serving a different package/component purpose?

No module is hidden, moved, renamed or deleted in this observation.

## Existing conceptual map

The repository already describes a conceptual hierarchy that is narrower than the raw Cabal module list.

The README and architecture documents present four library components:

```text
h-kernel
  Account, Money, Ledger, Journal, Actual, Plan, Budget,
  Engine, Report, application config, rendering primitives

h-kernel-household
  AccountProfile admission, HouseholdPolicy, DailyTarget,
  Backing, BudgetMovement, Issue admission

h-kernel-editor
  typed edit intent, candidate preparation, source placement,
  safe writer, Actual workspace, UI-independent interaction

h-kernel-spike-household-report
  provisional Household Report composition and rendering
```

Delivery adapters are described separately from those libraries.

This means a reader is already taught to start from domain/component responsibilities rather than from an alphabetic list of every exposed module.

## Measurement

A temporary branch-only GitHub Actions observer read:

- the four Cabal library `exposed-modules` fields;
- every Haskell source file under the stable libraries, spike library, delivery adapters, tests and tools;
- module declarations;
- explicit export-list shape;
- direct imports, classified as library, delivery, test or tool use.

The observer did not compile code and did not attempt semantic call-graph analysis. Import counts are therefore source-shape evidence, not API importance scores.

### Measurement correction

The first observer keyed importer records by declared module name. Because test suites and executables contain many modules named `Main`, those records overwrote one another and under-counted delivery/test imports.

That first importer result was rejected.

The observer was corrected to keep one importer record per source file. The corrected run completed successfully and is the only importer-count evidence used below.

This correction is itself useful evidence: package/API observations should not turn a convenience script into authority.

## Corrected surface inventory

Current Cabal exposure contains **65 modules**:

| Component | Exposed modules |
|---|---:|
| `h-kernel` | 38 |
| `h-kernel-household` | 10 |
| `h-kernel-editor` | 14 |
| `h-kernel-spike-household-report` | 3 |
| **Total** | **65** |

All 65 exposed module sources were located.

More importantly:

- **65 / 65** exposed modules have an explicit module export list;
- **0 / 65** use implicit export-all;
- **0 / 65** have zero in-repository direct importers.

So the current public surface is broad, but it is not an accidental consequence of modules exporting every declaration or of obviously orphaned exposed modules.

## Import-shape outliers

Direct importer shape produced only four notable outliers.

### Directly imported only by tests

Three exposed modules currently have test importers but no direct library, delivery or tool importer:

```text
HKernel.Budget.TSV
HKernel.HouseholdIssue.Render
HKernel.Plan.Render
```

This is not a deletion or de-exposure list.

#### `HKernel.Budget.TSV`

This module is an explicit strict admission owner for the historical `budget.tsv` shape. Its public API consists of the parser and typed admission diagnostics.

The current Household source inventory explicitly records that current Household Report composition does **not** read that old `budget.tsv` path. Current entitlement history is built from `budget_alloc.tsv` through `HKernel.Household.BudgetMovement.TSV` instead.

The source migration plan also points toward native `budget.journal` rather than treating the old TSV as the final h-kernel source shape.

However, the migration law explicitly rejects evidence-free retirement of retained compatibility surfaces. Test-only direct use therefore establishes neither deadness nor permission to hide/remove this module.

It is best classified for now as a **retained compatibility / migration admission surface** rather than a recommended first learning entrypoint.

#### `HKernel.HouseholdIssue.Render`

This is a 51-line pure renderer with one explicit public function, `renderHouseholdIssueLine`.

Its module comment states a useful semantic contract: publish every household-facing issue field without truncating or inferring information.

The fact that current direct repository use is test-only does not make that contract architecturally accidental. It is a compact example of a pure presentation boundary.

#### `HKernel.Plan.Render`

This is a 46-line pure renderer with one explicit public function, `renderCommittedOutgoingPlanLine`.

Its module comment deliberately excludes completion status because completion must first be derived from Plan-to-Actual evidence. That distinction is educational domain semantics, not merely formatting code.

Again, current direct repository use being test-only does not establish that it should be hidden.

### Exposed-library-only direct use

One exposed module has direct importers only among other exposed library modules:

```text
HKernel.Render.TerminalStyle
```

This module is not simply an unused implementation helper. It is imported by rendering owners including the separate spike library component. Because `h-kernel-spike-household-report` depends on `h-kernel`, that cross-component use currently gives Cabal exposure an architectural role.

Its public API is also deliberately explicit, separating width-bearing plain text from ANSI-decorated publication and owning terminal-specific table/width primitives.

Changing its Cabal visibility would therefore be a component-boundary change, not merely teaching-map cleanup.

## What Cabal exposure currently means

The observation suggests that `exposed-modules` is doing several jobs at once:

1. **domain/public API**
   - `HKernel.Money`
   - `HKernel.Account`
   - `HKernel.Ledger`
   - `HKernel.Journal`
   - `HKernel.Plan`
   - `HKernel.Budget`
   - `HKernel.Report`

2. **source admission and effect boundary**
   - `*.Journal`
   - `*.TSV`
   - `*.Config`
   - `HKernel.Loader`

3. **projection and presentation surface**
   - named Report modules
   - `*.Render`
   - `HKernel.Report.Presentation`
   - `HKernel.Render.TerminalStyle`

4. **application/editor API used by delivery adapters**
   - `HKernel.CLI`
   - `HKernel.Editor.CLI`
   - editor candidate/writer/interaction modules
   - `HKernel.Household.Application`

5. **provisional cross-component API**
   - `HKernel.Spike.HouseholdReport`
   - `HKernel.Spike.HouseholdReport.Render`

6. **retained compatibility / migration API**
   - most clearly `HKernel.Budget.TSV`

These roles do not have the same teaching priority even when Cabal must expose them with the same mechanism.

## Central observation

The current problem is not well described as **public API sprawl**.

A better description is **public-role flattening**:

> Cabal exposure answers which modules other Cabal components/consumers may import. It does not answer which modules a learner should read first.

The repository's README and architecture documents already provide a more meaningful conceptual map than the flat set of 65 exposed modules.

Trying to make Cabal exposure itself become the learning sequence would risk damaging legitimate component boundaries merely to improve navigation.

## Candidate learning-surface classification

Without changing any package API, a future teaching map could distinguish:

```text
1. Foundations
   Money -> Account -> Ledger

2. Source meaning
   Journal -> Actual.Journal / Plan.Journal -> Loader

3. Accounting and policy transformations
   Engine -> Budget / Plan / Household policy owners

4. Projections
   Report and named Report modules

5. Effect-safe editing
   typed editor intent -> candidate -> admission -> writer

6. Presentation and delivery
   Render / TerminalStyle -> CLI / TUI adapters

7. Migration and provisional surfaces
   retained compatibility admissions and spike composition
```

This is only a classification hypothesis. It does not justify creating umbrella facade modules, re-export modules, a generic framework, or a new package layer.

A small documented reading path may be enough.

## Relation to Weeder Observation 001

The Weeder experiment found:

```text
183 executable-strict findings
  -> preserve all 65 exposed modules
  -> 2 residuals
  -> both verified as test-used
  -> 0 verified deletion candidates
```

This public-surface observation adds a different lesson:

- preserving all exposed modules was the correct conservative reachability model;
- that does not make all 65 modules equal teaching roots;
- reachability, Cabal visibility and pedagogical importance are three different coordinates.

Future subtraction audits should continue to preserve required package/public/test roots before deletion conclusions.

## Decision

**Keep the current Cabal exposure unchanged.**

Do not de-expose, rename or delete modules from importer counts alone.

Do not introduce a facade/re-export architecture merely to make the public list shorter.

If navigation remains a real teaching problem, the next low-risk step is to observe or document a **recommended reading path** using the existing domain/component owners.

Any future Cabal narrowing must be owner-by-owner and must verify:

- cross-component consumers;
- executable/test consumers;
- migration/compatibility purpose;
- public teaching value;
- downstream/API assumptions;
- normal full CI.

## Repository effect of this observation

No production Haskell, Cabal exposure, dependency direction, source format, private source contract or writer authority is changed.

The temporary measurement workflow is removed after evidence collection.

The persistent result is this observation document only, plus its `docs/INDEX.toml` registration.
