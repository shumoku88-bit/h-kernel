# Long-Term Identity and External Evidence Observation

## Purpose

This document establishes permanent architectural guardrails for identity, external evidence, and domain boundaries in `h-kernel`. It ensures that core ledger primitives (`Account`, `Posting`, `Transaction`) remain small and rigorous, preventing them from becoming a bag of optional fields for future workflow features, bank imports, or business suite extensions.

## Current Evidence

The core double-entry kernel (`HKernel.Ledger`, `HKernel.Account`, `HKernel.Journal`) maintains explicit accounting facts:

- `Account`: canonical declared identity and typed role.
- `Posting`: immutable monetary movement on a declared Account.
- `Transaction`: balanced collection of 2+ Postings with an accounting date and description.

Multi-posting transactions already provide the accounting structure required for gross/net, fee, and tax movements without adding optional fields to `Transaction`.

## Non-Equivalences to Preserve

Future work must preserve these six fundamental non-equivalences:

```text
identity != current label
canonical fact != external observation
derived balance != asserted external balance
description != counterparty identity
financial fact != documentary evidence
accounting event != workflow object
```

A core accounting primitive must not collapse two distinct meanings merely because an external source or temporary workflow presents them together.

## Guardrails

- **Keep core primitives small**: Do not add optional payee, counterparty, document path, statement, import batch, invoice, or reconciliation fields to `Account`, `Posting`, or `Transaction`.
- **Distinguish external observations from Actual facts**: External bank rows, CSV feeds, or AI extractions are candidate evidence, not canonical `Actual` events. Admission must remain explicit and attributable.
- **Keep derived balance distinct from asserted balance**: Balance assertions compare derived `Balance` with external statement evidence. They must fail closed on disagreement rather than manufacturing balancing transactions.
- **Preserve historical evidence**: Account closure or label renames must not alter historical posting evidence or rewrite past transaction identities.

## Explicit Non-Goals

This observation does not authorize:

- Payee or Counterparty domain types attached to `Transaction`;
- bank, card, or CSV import engines inside the core ledger;
- reconciliation engines or auto-balancing assertion generators;
- document store, receipt OCR, or file attachment fields on core primitives;
- Invoice, Customer, or Vendor business-suite subsystems;
- optional `grossAmount`, `netAmount`, `fee`, or `tax` fields on `Transaction`;
- generic secondary date fields (`transactionDate2`);
- modifying `Account`, `Posting`, or `Transaction` primitives without a concrete, named owner.

## Decision

The strength of `h-kernel` lies in keeping its core ledger small, verified, and immutable. Later external evidence, import tools, or workflow capabilities should relate to the core through named validated projections rather than by inflating core primitives with speculative optional fields.
