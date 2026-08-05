# Actual reverse durable provenance decision 001

ステータス: E8c canonical reverse provenance decision  
Owner: Actual reversal identity and provenance contract  
基準日: 2026-08-06  
基準 h-kernel main: `302f6e998eb5a08e25dded5361d1d707a9167628`  
基準 bqn-ledger main: `e35203c856ef27fed52dfe955825472104823198`

## Decision

Actual reverseのcanonical source contractは、元Transactionを変更または削除せず、Actual Journalへ次の一Transactionを追加する形とする。

1. 元Transactionの全Postingを、順序とCommodityを保ったままexactに反転する。
2. 取消Transactionは新しいdurable `event-id`を持つ。
3. 取消Transactionは`reverses` metadataで対象のdurable Actual identityを明示する。
4. 同じtargetを直接二回reverseしない。
5. 取消Transaction自身を別の新しいTransactionでreverseすることは許可する。
6. description、金額、日付、Account shapeからtarget relationを推測しない。

最小source shapeは次である。

```journal
YYYY-MM-DD description
  ; event-id: NEW-REVERSAL-ID
  ; reverses: TARGET-ACTUAL-ID
  account:a  INVERSE-AMOUNT COMMODITY
  account:b  INVERSE-AMOUNT COMMODITY
```

raw indentationとstatus markerはsemantic identityではない。`event-id`、`reverses`、admitted Transactionが意味を所有する。

## Why this contract

取消は「反対符号のよく似た取引」ではなく、「どのActual factを否定したか」というprovenance edgeである。

explicit relationを残すことで次をsource自身から検証できる。

- targetが存在する
- reversal identityが一意である
- targetとreversalが同一identityではない
- 同じtargetへのdirect reversalが重複していない
- reverse-of-reverseが別の明示edgeとして表現される
- description変更や同額Transactionの存在に影響されない

`[reverse]` prefixだけでは、表示上の意図は示せても、typed target relationを再構築できない。

## Current h-kernel status

current `HKernel.Editor.ActualReverse`はこのdecisionをすでに実装している。

- explicit new Actual identityを要求する
- explicit target Actual identityを要求する
- target not foundを拒否する
- duplicate reversal identityを拒否する
- direct duplicate reversalを拒否する
- inverse postingsを生成する
- candidate complete sourceをstrict parse-backする

`HKernel.Actual.Journal`は`event-id`と`reverses`をtyped projectionとしてadmitし、unknown target、self-reference、duplicate target relationを拒否する。

このdecisionはcurrent Haskell behaviorを弱めず、source contractとして明文化する。

## Current bqn-ledger status

current BQN reverse pathはinverse postingsと`[reverse]` descriptionを追加するが、new durable `event-id`とexplicit `reverses` relationを生成しない。

さらにcurrent `src/editor/journal_profile.bqn`の`supportedMetadata`には`reverses`が含まれず、unsupported metadataはfail closedで拒否される。

したがって、Haskell形式のreversal blockをcurrent BQN readerへそのまま追加すると、BQN側のcomplete Journal admissionが通るとはみなせない。

これはrendering差ではなく、readerとwriterの両方にあるcontract gapである。

## Dual-editor consequence

Actual reverseは、current状態ではdual-editor pilot対象から除外する。

```text
before h-kernel writer cutover
  canonical reverse writer = current BQN writer
  h-kernel reverse = synthetic / non-canonical rehearsal only

after h-kernel writer cutover
  canonical reverse writer = h-kernel
  current BQN reverse must not target canonical source
  current BQN reader must not be assumed to admit new reversal metadata
```

BQN editorをcanonical sourceへ再び向けるには、少なくとも次が必要である。

1. BQN Journal admissionが`reverses`をrecognized metadataとしてadmitする。
2. target identityの存在とuniquenessを検証する。
3. reversal自身のdurable `event-id`を要求する。
4. self-referenceとduplicate direct reversalを拒否する。
5. BQN reverse writerがnew identityとtarget relationをcandidateへ書く。
6. h-kernel comparison harnessでidentityとreversal targetが一致する。

このadaptationはbqn-ledger側の別sliceであり、このdecision PRでは実装しない。

## Migration boundary

このdecisionはActual Journal内部のreverse contractだけを扱う。

変更しないもの:

- current canonical writer authority
- private canonical source
- existing historical reversal blocks
- Account source topology
- Plan source topology
- Budget、Issue、policy
- shared source-root lock
- source format migration
- UI

既存のidentity-free BQN reversalを自動rewriteしない。historical source cleanupは別の明示的なprovenance migrationとしてのみ検討する。

## Cutover effect

このdecisionにより、editor cutover readinessのGate 6に対するdesired contractは確定するが、gate自体はまだSatisfiedではない。

残る条件:

- current BQN reader/writerとのcompatible routeまたは明示的なoperation exclusion
- shared source-root serialization
- private non-canonical rehearsal
- operational cutover rule

Gate 8のsemantic comparisonでは、Actual reverseのexpected resultを「現在の差を受容する」から「canonical contractへ収束させる」に更新する。

## Next finite slice

次はActual multi-posting add semantic comparisonとする。

有限な問い:

> same input intentから生成されたBQN candidateとHaskell candidateは、2 postingを超えるTransactionでも、ordered Posting、exact Quantity、Commodity別balance、zero rejection、identity projectionについて同じadmitted meaningへ収束するか。

次sliceでは次を混ぜない。

- reverse implementation change
- bqn-ledger parser change
- Budget / Issue comparison
- shared lock
- private source rehearsal
- Account / Plan source topology
- canonical cutover
