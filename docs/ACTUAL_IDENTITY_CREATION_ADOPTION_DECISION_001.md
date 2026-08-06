# Actual durable identity creation and adoption decision 001

ステータス: 承認済みのdurable identity creation & adoption contract  
Owner: Actual transaction identity policy, durable generation, historical adoption contract  
承認日: 2026-08-06

## 1. Status and owner

本文書は、`h-kernel`におけるActual transactionのdurable identityの自動生成方針および、既存のidentityを持たないhistorical transactionに対する単一確定的なadoption contractを定義する決定文書である。

本決定は設計判断と契約の確立のみを所有し、identity generator、Actual addのコード変更、source rewrite engine、adoption UI、reverse TUIの実装を含まない。

## 2. Question

h-kernelがcanonical Actual writerとなった後、今後作成するActual transactionへどのidentityを永続化し、既存のidentity-free transactionへどのような明示的操作でidentityをadoptできるようにするか。

この問いを以下の4つの領域へ分解し、決定を下す。

1. **Future creation policy**: 今後生成する新Transactionに対する永続化方針
2. **Identity generator ownership**: generatorの所有境界およびライフサイクル
3. **Historical no-identity adoption policy**: identityを持たない既存Transactionへの適用方式
4. **Plan-derived compatibility policy**: `plan-id`由来のruntime identityとの互換性・移行分離

## 3. Current identity inventory

現在のh-kernel Journal parser (`HKernel.Actual.Journal`) は、Journal sourceから以下の3種類のidentity分類を認識・投影する。

### 1. Explicit event identity

* **Source形式**:
  ```journal
  ; event-id: VALUE
  ```
* **Projection**: `ActualWithExplicitEventIdentity ActualTransactionId`
* **性質**:
  * sourceへ直接永続化される。
  * externally durableな識別子である。
  * 重複（duplicate event-id）はstrict admissionによって拒否される。
  * reversal transaction自身には必須の属性である。
  * reversal targetとして利用可能である。

### 2. Plan-derived runtime identity

* **Source形式**:
  ```journal
  ; plan-id: PLAN-ID
  ```
  （`event-id` が付与されていない場合）
* **Runtime identity構築**: `plan-completion-<plan-id>`
* **Projection**: `ActualWithPlanDerivedRuntimeIdentity PlanId ActualTransactionId`
* **性質**:
  * sourceへ生成 identity を書き戻さない。
  * 再構築可能な runtime identity である。
  * externally durable な event identity ではない。
  * Plan completion relationの特定に利用される。
  * 現在の reverse target resolution でも利用可能である。
  * sourceに explicit `event-id` を後から書き加えると、effective identity が explicit identity へ切り替わる。

### 3. No identity

* **Source形式**: メタデータを持たない通常のTransaction
* **Projection**: `ActualWithoutIdentity`
* **性質**:
  * 現行の ordinary Actual add TUI はこの形式を生成する。
  * 会計上の事実（accounting fact）として完全にvalidである。
  * Read-only transaction browserで表示・選択可能である。
  * durableまたはderived target identityを持たない。
  * 現行の Actual reverse では target として選択できない（`TargetNotFound` 相当）。

## 4. Constraints

* PR #37, #38, #39, #40 をmergeしない。
* auto-merge および branch 削除を行わない。
* 既存ソースの3分類に対するreader compatibilityを維持する。
* 本sliceではコード実装、リライトエンジン、UI改修を行わない。
* private canonical sourceへアクセスせず、合成データ（synthetic fixtures）のみを使用する。
* safe writerの所有権（stale check, backup, atomic publication, post-admission, restore）を変更せず、safe writer内に identity 生成を混入させない。

## 5. Future creation decision (Decision A)

h-kernelが今後 canonical source へ新しく書き込む Actual transaction は、原則として source へ explicit `event-id` を永続化する。

* **適用対象**:
  * ordinary Actual add
  * future Actual multi-posting add
  * Plan finish が生成する Actual
  * Actual reverse（現状すでに `event-id` 必須の規則を満たしている）
  * その他、将来h-kernelが新規生成する canonical Actual transaction
* **補足**:
  * Actual reverse は既存実装（`HKernel.Editor.ActualReverse`）ですでにこの基準を満たしている。
  * ordinary add、multi-posting add、Plan finish は、本決定の後の個別実装sliceにおいてこの規則へ統一する。本sliceではコード変更を行わない。

## 6. Generator ownership (Decision D)

Identity generator の所有権境界を以下のように確定する。

### Selected owner

```text
HKernel.Editor.ActualIdentity
```

Identity generator の所有権は、`HKernel.Editor.ActualIdentity` モジュールに一意に確定する。

### 将来本モジュールが所有するもの

* Actual identity generation request
* generator injection boundary
* generated Text の `ActualTransactionId` admission
* existing admitted identity との collision 確認
* 有限 retry または typed failure
* identity format implementation

### 本モジュールが所有しないもの

* Journal parsing
* Transaction rendering
* safe publication
* backup / restore
* stale detection
* TUI navigation
* Plan identity generation
* historical source rewrite

### Existing domain typeとの関係

既存のドメイン型および検証関数を再定義しない。

```haskell
HKernel.Plan.Completion.ActualTransactionId
HKernel.Plan.Completion.mkActualTransactionId
```

`HKernel.Editor.ActualIdentity` は、新しい identity 型を並行して作るモジュールではない。

本モジュールの役割は以下の通りである。

```text
opaque/random candidate Text
  -> mkActualTransactionId
  -> admitted ActualTransactionId
  -> collision check
```

`ActualTransactionId` の domain validation ownership は既存の `HKernel.Plan.Completion` に残す。

### Application adapterとの関係

TUI または CLI adapter は、operation 開始時または最初の valid preview 前に `HKernel.Editor.ActualIdentity` へ identity を要求する。生成された identity は同一 operation 内で固定する。

以下のモジュールへ生成処理を置かない。

* `HKernel.Actual.Journal`
* `HKernel.Editor.ActualWriter`
* `HKernel.Editor.TransactionBlock`
* rendering helper

### Format gateとの分離

Generator owner は今回 `HKernel.Editor.ActualIdentity` に一意に確定するが、具体的な ID フォーマット（UUID v4, UUID v7, ULID, opaque random token 等）の最終選択は、引き続き次実装 slice 冒頭の有限 gate として残す。

「owner 候補（確定済み）」と「format 候補（次 slice gate）」を明確に区別する。

## 7. Generation timing (Decision E)

生成された identity のライフサイクルおよび確定タイミングを以下のように決定する。

* **確定タイミング**:
  * 生成された identity は、最初の valid preview を作成する前に確定する。
* **同一Operation内での不変性**:
  * 同一 operation 内では、以下の状態遷移の間、全く同じ identity を保持する。
    ```text
    valid preview
      -> back to input
      -> preview again
      -> confirmation
      -> publication
      -> stale rejection
    ```
  * preview と publication の間で identity を再生成してはならない。
  * 入力を修正して再 preview を行った場合であっても、同じ operation セッション内であれば identity を変化させない。
* **未出版IDの扱い**:
  * ユーザーが operation をキャンセル、あるいは完了して Hub へ戻り、新しく Actual add を開始した場合は、新しい identity リクエストとする。
  * キャンセル等により未出版となった identity が欠番になることは完全に許容する。identity を連番の会計証憑として扱わない。

## 8. Identity format requirements and format gate decision (Decision F)

Identity のフォーマットおよび生成仕様を以下のように確定した。

* **Selected format**: `evt-` + UUID v4 canonical lowercase text (例: `evt-550e8400-e29b-41d4-a716-446655440000`)
* **Generator owner**: `HKernel.Editor.ActualIdentity`
* **Canonical creation admission boundary**: `HKernel.Editor.ActualIdentity.admitActualEventIdentityText` (exact `evt-` prefix, canonical lowercase hyphenated UUID text, version 4 nibble, RFC variant nibble in `8`, `9`, `a`, `b`, and domain `mkActualTransactionId`)
* **Production source**: `Data.UUID.V4.nextRandom` (h-kernel-editor library build-depends: `uuid >= 1.3.16 && < 1.4`)
* **Domain storage type**: `HKernel.Plan.Completion.ActualTransactionId` (no redundant domain types)
* **Collision set**: fresh admitted `ActualJournal` が持つすべての effective Actual identities (`actualJournalIdentifiedTransactions` / `identifiedActualId`)（explicit event identity と plan-derived runtime identity の両方）
* **Retry policy**: 有限リトライ (`actualIdentityAttemptLimit = 8`)
* **Sanitized failure**: candidate, existing IDs, source text, path, IOException をログや UI State に保持しない
* **TUI lifecycle**: `OperationActualAdd` 開始時に 1 回のみ生成し、同一 operation 内（preview, back, confirmation, publication）で固定
* **CLI contract**: CLI `append` では自動生成を行わず、オペレータが明示的に `<evt-uuid-v4>` を指定する契約（`h-kernel-editor-cli append [--commit] <journal.txt> <evt-uuid-v4> <YYYY-MM-DD> <desc> ...`）。`admitActualEventIdentityText` による判定を共有し非 canonical ID を拒否する。
* **Historical reader compatibility**: 既存 source 内の legacy event IDs, plan-derived IDs, no-identity transactions は上位互換として維持し、新規 creation 入口（ordinary add TUI, CLI append, generator injection）のみに本 admission を適用する。


## 9. Plan completion compatibility (Decision B)

`plan-id` の役割と identity の分離について以下を定める。

* **役割の分離**:
  * `plan-id` は Plan completion relation の座標（coordinate）であり、新規 Transaction の durable identity の代替とはしない。
* **将来のPlan finish構造**:
  * 将来の Plan finish が生成する Actual Transaction は、最終的に以下の両方を保持する方向とする。
    ```journal
    ; event-id: EXPLICIT-ACTUAL-ID
    ; plan-id: PLAN-ID
    ```
  * `event-id` が Actual fact の durable identity であり、`plan-id` は Plan completion relation を表す。二つを同一の coordinate として扱わない。
* **既存Plan識別子の維持**:
  * 既存 source に存在する `plan-id` のみの Transaction（`ActualWithPlanDerivedRuntimeIdentity`）は引き続き valid として扱う。
  * 既存 source を自動 rewrite しない。

## 10. Historical adoption decision

過去の identity を持たない Transaction に対する adoption 方針を以下のように決定する。

* **対象範囲**:
  * adoption の対象は **`ActualWithoutIdentity` のみ** とする。
  * `ActualWithExplicitEventIdentity` および `ActualWithPlanDerivedRuntimeIdentity` は初期 adoption の対象外とする。
* **Plan-derived を初期対象としない理由**:
  * `plan-id` のみの Transaction へ後から explicit `event-id` を追加すると、現在の parser 仕様では effective identity が explicit identity へ切り替わる。
  * その結果、既存の `reverses: plan-completion-<plan-id>` や Plan completion 参照（runtime identity references）が破綻するリスクがある。
  * したがって、Plan-derived から explicit identity への upgrade は、alias compatibility や reference migration を伴う別の設計決定とし、本 no-identity adoption とは明確に分離する。
* **No-identity adoption contract**:
  * 既存の no-identity transaction へ identity を与える操作は、オペレータが 1 件ずつ明示的に選択する専用 operation とする。
  * **禁止事項**:
    * 起動時の自動バックフィル（bulk backfill）
    * 全履歴への一括リライト
    * browser を開いただけで暗黙 adopt
    * reverse ボタンを押しただけで暗黙 adopt
    * date, description, amount, posting からのターゲット推測
    * transaction hash や source index の永続 identity 化
    * 内容が重複する Transaction の自動選択
    * plan-derived transaction の暗黙 upgrade
  * **許可される将来のフロー**:
    ```text
    fresh admitted snapshot
      -> operator selects one source-aligned no-identity record
      -> application generates or receives new explicit event-id
      -> exact selected transaction blockへevent-id metadataを挿入
      -> complete candidate sourceをstrict parse-back
      -> selected transactionのaccounting semanticsが不変であることを比較
      -> explicit confirmation
      -> safe whole-source publication
      -> post-admission
    ```

## 11. Source-position locator boundary

* **Operation Locator の定義**:
  * source index または source span は、不変な operation snapshot 内で対象の Transaction block を特定するための一次的な **operation locator** としてのみ利用可能とする。
* **Boundary の分離**:
  * operation locator 自体を durable identity として保存・永続化してはならない。
  * 以下の概念区別を決定文書として明確に保持する。
    ```text
    operation locator:
      source index / source span
      snapshot内でのみ有効

    semantic identity:
      explicit event-id
      sourceへ永続化される
    ```

## 12. Adoption semantic invariants

Identity adoption 実装が満たすべき普遍の不変条件（semantic invariants）を定める。

Adoption 前後において以下は**絶対に不変**でなければならない。
* date
* description
* posting count
* posting order
* Account
* exact Quantity
* Commodity
* status marker の意味
* existing metadata
* reversal relation
* Plan relation
* transaction source order

変更が許可されるのは、対象 Transaction の identity coordinate のみである。
```text
ActualWithoutIdentity
  ->
ActualWithExplicitEventIdentity NEW-ID
```

* Transaction 数を増減させてはならない。
* posting を改変してはならない。
* 元 Transaction を削除して新しい Transaction を末尾へ append する方式をとってはならない。

## 13. Reverse eligibility

Transaction browser における各行の Reverse 操作に対する適格性（Reverse eligibility）を以下のように定義する。

* **Explicit event identity**:
  * Reverse target **eligible**（反転可能）
* **Plan-derived runtime identity**:
  * 現行 contract 上は Reverse target **eligible**（反転可能）。
  * ただし UI 上では durable identity として表示しない。
* **No identity**:
  * Reverse target **ineligible**（反転不可）
  * Identity adoption が必須となる。
  * 将来の UI において no-identity 行が選択された場合は、以下のいずれかへ誘導する。
    * `Adopt Identity`
    * `Back`
  * Reverse 操作と Adoption 操作を同一の write operation へ混在させてはならない。

## 14. Rejected alternatives

以下の代替案は明確に**拒否（reject）**する。

1. **Reject: content-derived identity**
   * (date + description + amount), posting hash, whole transaction hash, source text hash など。
   * **理由**: 編集やフォーマット変更で変化する。同一内容の重複取引を区別できない。ビジネスファクトと識別子を混同している。プライバシー漏洩のリスクがある。
2. **Reject: source-position identity**
   * line number, transaction index, byte offset など。
   * **理由**: 前段のソース変更によって容易に変化するため、durable reference にならない。
3. **Reject: silent bulk backfill**
   * **理由**: 履歴ソース全体を不用意に変更し、レビュー不能な巨大 diff を生む。意図しない変更やプライバシーリスクを伴う。
4. **Reject: plan-derived identity の一括 explicit 化**
   * **理由**: 既存の参照関係を破壊するおそれがあり、alias/migration 契約が未決定であるため。
5. **Reject: writer-side hidden generation**
   * **理由**: プレビューした candidate と出版される candidate が一致しなくなる。テスト可能性が低下する。

## 15. Privacy boundary

* private canonical source へのアクセスを厳禁とする。
* 実データ（private paths, real accounts, dates, amounts, descriptions, hashes）を文書やログ、テストに含めない。
* すべての例示およびテストデータは、独立した合成値（synthetic values）のみを使用する（例: `evt-synthetic-001`, `plan-synthetic-001`）。

## 16. Writer and parser boundaries

本決定は以下の所有権構造を変更しない。
* canonical `actual.journal` writer = `h-kernel` editor
* `bqn-ledger` Actual write = 禁止
* その他のソースの writer authority = 変更なし
* Safe publication writer の責任（stale check, backup, atomic publication, post-admission, restore）に identity 生成を追加しない。

## 17. Migration boundary

本決定はソースコードの破壊的移行を行わない。
既存のソースファイル形式や reader の上位互換性を維持する。

## 18. Ordered implementation slices

本決定後の実装順序を以下の通り確定する。

1. **I1. ordinary Actual add durable identity creation** (次の一つの有限slice)
2. **I2. shared identity generator adoption by other future Actual creators**
3. **I3. source-aligned no-identity adoption engine**
4. **I4. read-only browser adoption entrypoint**
5. **I5. Actual reverse TUI**

次の一つの有限sliceは、必ず **ordinary Actual add durable identity creation** とする。
Adoption の実装や Reverse TUI を次 PR に混在させてはならない。

## 19. Completion condition

以下の検証がすべて成功した時点で本 slice は完了とする。

* 本文書 `docs/ACTUAL_IDENTITY_CREATION_ADOPTION_DECISION_001.md` の作成。
* `docs/INDEX.toml` および `docs/TUI_OPERATION_HUB_PLAN_001.md` の整合的更新。
* `cabal build all`, `cabal test all`, `cabal run exe:repository-audit`, `./report-build && ./report-verify --fixture` のパス。
* Code / logic の変更がないこと（docs-only slice）。
* PR #37, #38, #39, #40 および自 PR の merge なし。
