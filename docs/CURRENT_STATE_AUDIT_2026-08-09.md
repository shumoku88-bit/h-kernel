# h-kernel current-state architecture audit — 2026-08-09

ステータス: current-state observation  
Owner: h-kernel current capability / architecture debt / bqn-ledger comparison snapshot  
Baseline: `main` `0b451366aa3ac106c43f60a96fe6bc1d86075e34`  

## 1. Purpose

この文書は、2026-08-09時点の`h-kernel`を、実際のremoteとcurrent main codeから棚卸しした観察記録である。

これは将来仕様そのものではない。今後の順序とactive targetは`EDITOR_DEVELOPMENT_PLAN.md`が所有する。

比較対象はcurrent `bqn-ledger`、shared canonical sourceはprivate `household-ledger-data`である。private sourceの実値はこの文書へ記録しない。

## 2. Remote baseline

### h-kernel

- `main`: `0b451366aa3ac106c43f60a96fe6bc1d86075e34`
- latest commit: `feat(tui): add contextual Actual reversal (#104)`
- open PR: 0
- audit後にmerged branch群は削除され、remote branchは`main`のみ
- latest main CI: GHC 9.10.3 / 9.12.4 / 9.14.1 success
- GHC 9.10.3 ownership audit success
- complete report contracts success

### bqn-ledger

Audit時点のcurrent mainは`0d5ababf87cd579e92c28a1b361b334e58800217`。canonical Household recoveryは進行中で、current editor capabilityとcanonical write qualificationを同一視しない。

### canonical Household

shared target rootは次の8ファイルである。

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

private repositoryには8ファイルが存在する。同時にlegacy migration evidenceも残っているため、canonical v1の成立とlegacy retirement完了は別である。

## 3. Current conclusion

h-kernelは、最優先の日常操作のうち、ordinary Actual、3+ posting Actual、Plan completion、successor replenishment、Actual Reverse、主要ReportをBrick TUIから完結できる。

一方、Account add、Budget movement、Issue add/close/drop、Plan add/editはdomainまたはCLI能力が先行し、current TUIへは接続されていない。

Haskell側はtyped identity、explicit provenance、exact Quantity、Commodity、NonEmpty Posting、complete canonical Household admission、Plan coordinated publicationでBQN版より強い境界を持つ。

最大のcorrectness debtは、single-file safe writerがpreview stale rejectionを持ちながら、rename直前の再stale checkとchecked rollbackを持たないことである。canonical Actual writer authorityを担う以上、次の機能追加より先に締める価値が高い。

最大のdelivery architecture debtは`editor-tui-app/Main.hs`への責任集中である。問題は行数そのものではなく、rendering、event routing、form construction、operation orchestration、publication、reloadが一つのBrick adapterに集まっていることにある。

## 4. Capability matrix

| Capability | Domain | CLI | TUI | Publication | Current practical status |
| --- | --- | --- | --- | --- | --- |
| Daily Actual | yes | yes | yes | Actual safe writer | daily usable |
| Multi-posting Actual | yes | yes | yes | Actual safe writer | daily usable |
| Actual Reverse | yes | yes | yes | Actual safe writer | daily usable |
| Plan add | yes | yes | no | Plan single-file writer | CLI only |
| Plan edit | yes | yes | no | Plan single-file writer | CLI only |
| Plan -> Actual | yes | yes | yes | Actual writer | usable |
| Complete & Advance | yes | low-level CLI operations remain separate | yes | coordinated Actual + Plan publication | usable |
| successor Plan replenishment | yes | composable | yes | coordinated publication | usable |
| Account add | yes | yes | no | accounts.journal publication | CLI only |
| Account edit | no | no | no | no | not implemented |
| Budget movement | yes | yes | no | budget.journal publication | CLI only |
| Income transaction | accounting domain supports it | generic append | expressible through postings | Actual writer | no dedicated workflow |
| Transfer | accounting domain supports it | generic append | expressible through postings | Actual writer | no dedicated workflow |
| Issue add | yes | yes | no | shared publication effect | CLI only |
| Issue resolve | yes, stable IssueId | no current CLI route | no | candidate + shared publication effect | not human-connected |
| Issue drop | yes, typed Dropped | no current CLI route | no | candidate + shared publication effect | not human-connected |
| Reports | yes | yes | yes | read-only | usable |
| Account filtering/browsing | yes | not dedicated | yes | read-only | usable |
| canonical Household read | yes | application/report entrypoints | yes | read-only | usable |
| canonical source write | source-specific capability exists | partial | Actual + Plan daily paths | source-specific | authority must be treated separately |

## 5. Daily UX observations

### Ordinary Actual

Current flow is short and terminal-portable, but Account names are typed directly. Function keys, Ctrl keys, prefix sequences, and manual provenance IDs are not required.

The main remaining ergonomic debt is ordinary-key Account discovery. Direct typing is a complete fallback, not the desired final discovery experience.

### Multi-posting Actual

3+ Posting transaction entry is connected end-to-end. One selected posting row is edited at a time. This is functional but still carries more local interaction state than ordinary entry.

### Plan Complete & Advance

The semantic model is strong: nominal Plan date, Actual date, Actual amount override, successor date, and successor amount remain distinct. Actual and successor Plan are previewed together and published as one coordinated operation.

The UI still has an extra preview/confirmation key sequence compared with ordinary Actual.

### Actual Reverse

This is the strongest current workspace interaction and should be the model for later contextual operations.

```text
selected Actual transaction
  -> Enter
  -> Reverse
  -> edit date/description
  -> preview
  -> publish
```

The selected admitted identity is carried with the exact source-order transaction entry. Identity is not recovered from transaction equality or display text. The person does not type the target identity or provenance relation.

### Reports

The reports are usable, but report selection still depends substantially on letter shortcuts. A browse-and-Enter surface would better match the workspace law. Domain-only report capabilities such as the explicit Cycle Comparison type are not all first-class TUI choices yet.

### Account / Budget / Issue maintenance

These sections are primarily read-only in current TUI. This is the largest visible capability gap relative to the retained BQN command surface.

## 6. Haskell-native strengths

### Typed domain values

The design uses named domain values rather than treating all semantics as Text or numeric primitives.

Important examples include:

- `Account`
- `AccountType`
- `Commodity`
- exact `Quantity`
- `Amount`
- `PlanId`
- `ActualTransactionId`
- `IssueId`
- `IssueStatus`
- `NonEmpty Posting`

### Invalid-state exclusion

Transaction construction, quantity parsing, account admission, Plan identity admission, reversal relations, and complete source admission reject invalid values before later calculations consume them.

### Stable identity and provenance

`ActualTransactionEntry` retains the transaction and the identity assigned to that exact root-source position. Reverse and completion relations use explicit IDs instead of guessing from date, description, amount, Account, or equality.

### Pure transformation owners

Candidate preparation and accounting calculation generally live outside delivery adapters. Brick does not own balance validation, reversal semantics, Plan recurrence semantics, or Report calculation.

### Canonical Household admission

`HouseholdRoot` resolves the eight canonical paths and `HKernel.Household.Application` assembles typed state while checking exact AccountRegistry agreement, Plan/Budget admission, policies, Report configuration, Issues, and Daily Target inputs.

### Coordinated Plan publication

Complete & Advance prepares both complete candidates before effect, stale-checks both sources, publishes them as a coordinated operation, then performs whole-Household post-admission with rollback support.

## 7. Architecture debt

### Critical: authoritative single-file publication race window

The current single-file writer has expected-old-bytes stale rejection, backup, sibling candidate, atomic rename, post-admission, and rollback.

It does not currently re-check the expected source immediately before publication. It also does not guard rollback by proving the target still contains the just-published candidate. Fixed temporary names further weaken cross-process behavior.

The project does not need a distributed locking framework. It does need a stronger publication law that prevents an operation from overwriting a write that occurred after its last stale check or rolling back over a later writer.

### High: admitted state and expected source bytes are not one snapshot

The TUI can load typed Household state and then separately read raw Actual/Plan bytes for publication expectations. These reads should eventually come from one application snapshot boundary so domain meaning and expected bytes describe the same observation.

### High: Actual publication success is narrower than complete Household success

Actual post-admission validates the resolved Actual graph. The TUI reloads the whole Household afterward. If the later whole-Household reload fails, the Actual write has already committed.

The canonical operation should eventually define whether whole-Household re-admission is part of publication success and restore on failure.

### High: Brick Main owns too many responsibilities

`editor-tui-app/Main.hs` owns the top-level Brick state machine, section rendering, form construction, event routing, operation preparation, publication orchestration, and reload behavior.

The desired subtraction is not arbitrary file splitting. Existing semantic owners should permit small delivery owners such as Actual and Plan controllers, while the top-level Main retains Brick application bootstrap, Household section navigation, and composition.

### High: production owners remain under Spike namespace/source tree

`HKernel.Spike.HouseholdReport` and canonical Household application dependencies now participate in production reports and TUI behavior. Their names and physical source placement no longer describe their responsibility.

This is an ownership/readability debt, not a correctness emergency.

### Medium: Plan CLI publication boundary lags Actual/Budget path-aware admission

Canonical Plan roots may use an include graph. Current Plan CLI mutation still has single-source publication paths where complete path-aware admission should be reviewed and aligned.

### Medium: compatibility routing remains in Editor CLI

The CLI still distinguishes canonical target paths from retained legacy source forms in some operations. Final canonical operation entrypoints should receive a Household root or canonical operation target instead of making compatibility fallback central.

### Medium: report delivery does not expose every typed report as a first-class selection

The domain has stronger distinctions than the current TUI list in some report areas. Delivery completion can follow after correctness and workspace ownership.

## 8. UX debt

UX debt is separate from architecture debt.

- ordinary Account discovery relies on typing canonical names after terminal-portability cleanup
- section navigation still uses `1-7`
- Report navigation still exposes many action letters
- Plan Complete & Advance has more confirmation steps than ordinary Actual
- Account/Budget/Issue sections do not expose contextual mutations
- Plan add/edit are not workspace operations
- dedicated income/transfer workflows are absent, although the accounting model already represents them

No UX debt above justifies weakening identity, provenance, exact arithmetic, Commodity, or source admission.

## 9. Subtraction candidates

### Repository state

Merged remote branches were deleted before this document was created. Current remote branch topology is `main` only.

### Code / ownership candidates

Retire only after focused evidence shows no retained caller or migration role:

- Transaction-only compatibility projection after all identity-sensitive Actual consumers use `ActualTransactionEntry`
- legacy CLI fallback branches after canonical writer/read cutover
- retained TSV builders after cross-engine migration evidence is no longer required
- `Spike` naming/location for production owners
- obsolete shortcut descriptions and superseded UI state once ordinary-key discovery replaces them

### Private legacy sources

Do not delete private legacy TSV/config/manifest files merely because h-kernel no longer needs them. bqn-ledger canonical recovery and source-specific deletion gates must complete first.

## 10. Comparison with bqn-ledger

The retained BQN application still exposes a broader set of explicit human operations, including Account add, expense, multi-posting, transfer/move, income, Budget movement, Plan add/edit/finish, reverse, Issue add, and Issue close.

That breadth does not imply canonical parity. bqn-ledger is still recovering those capabilities against the eight-file canonical Household root.

h-kernel is currently stronger in several semantic boundaries:

- typed identity rather than row/display coordinate at domain mutation boundaries
- explicit Actual reversal provenance
- exact Commodity-aware accounting values
- invalid-state exclusion through constructors/admission
- complete typed Household application admission
- coordinated Plan completion + successor publication
- compiler-enforced distinction among many domain coordinates

The target is not literal command parity. Retain the useful human accomplishment and accounting meaning, then redesign the delivery in a Haskell-native contextual workspace.

## 11. Audit outcome

The project is no longer primarily blocked by missing accounting primitives.

The next chapter should therefore be ordered as:

```text
publication correctness
  -> coherent canonical snapshot/publication boundary
  -> thin TUI ownership seam
  -> contextual maintenance operations
  -> UX/report completion
  -> compatibility and namespace subtraction
```

This ordering is developed in `EDITOR_DEVELOPMENT_PLAN.md`.
