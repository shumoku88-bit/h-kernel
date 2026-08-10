# Report Observation Benchmark

This tool measures the report work around one admitted canonical Household observation.
It exists to answer a narrow question after PR #135: once report projections are retained with the TUI `AppContext`, how much work remains in rendering and how much projection work was removed from one redraw?

It is deliberately separate from `report-benchmark`.

- `report-benchmark` measures the optimized `h-kernel` CLI as a fresh process.
- `report-observe` measures repeated work inside one already-running Household observation.

No benchmark framework, mutable cache, rendered-Text cache, or production report API is introduced.

## Run

Use the private canonical Household directory directly. The tool reads it but does not publish any source changes.

```bash
cabal run \
  --project-file=tools/report-observe/cabal.project \
  exe:report-observe -- \
  "$HKERNEL_LEDGER_DATA_DIR" 10
```

The second argument is the positive sample count and defaults to `10`.

Do not copy private source into this repository for benchmarking.

## Measurements

The benchmark first loads one canonical Household observation and forces one complete combined report as warm-up. It then reports:

- `load+project+render`: load a fresh `HouseholdWriteSnapshot`, resolve/build report projections, and render the combined report.
- `rebuild+render`: reuse the admitted `HouseholdState`, rebuild report projections, and render.
- `retained-render`: reuse the already prepared `ReportBook` and `HouseholdReportSurface`, then render again.
- `projection-placement delta`: average `rebuild+render - retained-render`.

`rebuild+render` approximates the report work that used to sit in the Brick redraw path before #135. `retained-render` approximates the current #135 placement, where projection values live with one `AppContext` observation and only presentation work is repeated.

The tool reads the state and prepared report through `IORef` before each sample. This prevents the benchmark loop itself from sharing one pure rebuild/render thunk across samples while keeping the measured values immutable.

## Interpretation

Treat the numbers as observations, not performance contracts.

- If `rebuild+render` is materially larger than `retained-render`, projection placement was a significant redraw cost and #135 removed real work from redraw.
- If `retained-render` is still large, measure/rendering should be investigated before adding more report projection abstractions.
- If `load+project+render` dominates while the other two are small, startup/source admission is the next place to observe.
- Do not infer that Haskell itself is the bottleneck from one wall-clock number.

Run on the machine and source shape whose interactive behavior matters. CI is useful for compiling the observer, but hosted-runner timing is not the user-performance baseline.
