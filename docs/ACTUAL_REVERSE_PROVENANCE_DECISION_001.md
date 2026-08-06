# Actual reverse durable provenance decision 001

ステータス: 承認済みのcurrent contract  
Owner: Actual reversal identity and provenance  
更新日: 2026-08-06

## 1. Decision

Actual reverseのcanonical source contractは、元Transactionを変更または削除せず、Actual Journalへ一つの新しいTransactionを追加する形とする。

1. 元Transactionの全Postingを、順序とCommodityを保ったままexactに反転する。
2. reversal Transactionは新しいdurable `event-id` (canonical `evt-UUID-v4` 形式) を持つ。
3. reversal Transactionは`reverses` metadataでtargetのActual identity (legacy explicit, canonical explicit, または plan-derived runtime) を明示する。
4. non-canonical new identity、unknown target、self-reference、duplicate reversal identityを拒否する。
5. 同じtargetを直接二回reverseしない。
6. reversal Transaction自身を、別の新しいTransactionでreverseすることは許可する。
7. description、amount、date、Account shapeからtarget relationを推測しない。

最小source shapeは次である。

```journal
YYYY-MM-DD description
  ; event-id: evt-550e8400-e29b-41d4-a716-446655440200
  ; reverses: TARGET-ACTUAL-ID
  account:a  INVERSE-AMOUNT COMMODITY
  account:b  INVERSE-AMOUNT COMMODITY
```

raw indentationとstatus markerはsemantic identityではない。`event-id`、`reverses`、admitted Transactionが意味を所有する。

## 2. Why explicit provenance

reversalは「反対符号の似た取引」ではなく、「どのActual factを否定したか」というexplicit provenance edgeである。

このrelationにより、source admissionは次を検証できる。

- target identityが存在する
- reversal identityが一意かつcanonical `evt-UUID-v4` 形式である
- targetとreversalが同一identityではない
- direct duplicate reversalがない
- reverse-of-reverseが別のexplicit edgeとして表現される
- description変更や同額Transactionの存在に依存しない

`[reverse]` prefixだけではoperator intentは示せても、typed target relationを再構築できない。

## 3. Current implementation

`HKernel.Editor.ActualReverse`はこのcontractを実装している。

- canonical new Actual event identity (`evt-UUID-v4`) を要求・検証する
- explicit target Actual identity (legacy explicit, canonical explicit, または plan-derived runtime) を要求する
- non-canonical new identityを拒否する (`InvalidReversalEventIdentity`)
- target not foundを拒否する (`TargetNotFound`)
- duplicate reversal identityを拒否する (`ReversalIdAlreadyExists`)
- direct duplicate reversalを拒否する (`TargetAlreadyReversed`)
- inverse postingsを生成する
- candidate complete sourceをstrict parse-backする

`HKernel.Actual.Journal`は`event-id`と`reverses`をtyped projectionとしてadmitし、unknown target、self-reference、duplicate target relationを拒否する。

このdecisionはHaskell behaviorを弱めず、readerとwriterが共有するsource contractとして固定する。

## 4. Current BQN compatibility

current BQN reverse pathはinverse postingsと`[reverse]` descriptionを追加するが、新しいdurable `event-id`とexplicit `reverses` relationを生成しない。

また、current BQN Journal profileが`reverses`をrecognized metadataとしてadmitしない場合、h-kernel形式のreversalを含むcomplete sourceをBQN readerへそのまま渡せるとは扱わない。

これはraw formatting差ではなく、identity、provenance、reader admissionのcontract gapである。

BQN reader/editorをこのcontractへ対応させる場合は、少なくとも次が必要である。

1. `reverses`をrecognized metadataとしてadmitする。
2. target identityの存在とuniquenessを検証する。
3. reversal自身のdurable `event-id`を要求する。
4. self-referenceとduplicate direct reversalを拒否する。
5. BQN reverse writerがnew identityとtarget relationを書く。
6. semantic comparisonでidentityとreversal targetが一致する。

このadaptationはbqn-ledger側の別sliceであり、この文書は実装を所有しない。

## 5. Single-user writer law

このprojectのcanonical editorは一人のoperatorが順番に使う。

```text
before h-kernel writer cutover
  canonical reverse writer = bqn-ledger
  h-kernel reverse = synthetic / explicit non-canonical rehearsal only

after explicit h-kernel writer cutover
  canonical reverse writer = h-kernel
  bqn-ledger writer is not used against canonical source
```

cross-process shared lock、dual-editor alternating canonical write、lock contention testはcutover要件にしない。

operatorがwriterを切り替えるときは、旧editorのoperationを終え、新しいeditorでlatest sourceを読み直す。preview後にsourceが変わった場合はcurrent stale-source rejectionがwriteを拒否する。

reader compatibilityはwriter serializationとは別問題である。cutover後もBQN reportまたはreaderをcanonical sourceへ向けるなら、BQN Journal admissionが`reverses`を読める必要がある。BQNをcanonical readerとして使わないなら、そのadaptationはcutover後の互換sliceへ送れる。

## 6. Daily-use command status

日常利用を`bqn-ledger`から`h-kernel`へ切り替えるためのcommand hubはmainへ導入済みである。

```text
tools/hk
  -> report
  -> edit
  -> check
  -> help
```

command hubは会計計算、source admission、source mutation、repository audit ruleを再実装しない。既存report launcher、`h-kernel-editor-cli`、repository checksへ引数とexit statusを渡すだけのdoorwayである。

したがって、この文書に以前置かれていた「次はcommand hubを実装する」という作業案は完了済みであり、current contractから削除する。

## 7. Remaining before canonical cutover

reverse implementationとcommand hubが存在することだけではwriter authorityは移らない。

残る条件は次である。

- explicit private non-canonical copyでh-kernel reverseを一度確認する
- daily-use operation setをnon-canonical copyで確認する
- canonical sourceがuntouchedであることを確認する
- cutover後もBQN readerを使うか決める
- readerを残す場合は`reverses` admissionへ対応させる
- h-kernel source selection、rollback時の唯一writer、restore failure時のstop procedureを決める
- 作者がcutoverを明示的に承認する

次の有限sliceは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)が所有する。

## 8. Migration boundary

このdecisionが変更しないもの:

- current canonical writer authority
- private canonical source
- existing historical reversal block
- Account、Plan、Budget、Issue、policy source topology
- source format migration
- UI implementation

既存のidentity-free reversalを自動rewriteしない。historical cleanupは、別の明示的なprovenance migrationとしてだけ検討する。
