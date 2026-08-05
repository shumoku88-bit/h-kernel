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

## Single-user cutover consequence

このprojectのcanonical editorは一人のoperatorが順番に使う。複数processによる同時writeや、二つのeditorを並行してcommitする運用はcutover要件にしない。

必要な運用規則は小さい。

```text
before h-kernel writer cutover
  canonical reverse writer = current BQN writer
  h-kernel reverse = synthetic / non-canonical rehearsal only

after h-kernel writer cutover
  canonical reverse writer = h-kernel
  current BQN writer is not used against canonical source
```

同時writeを防ぐshared lockは要求しない。operatorがwriterを切り替えるときは、旧editorの操作を終えてから新editorで最新sourceを読み直す。current stale-source rejectionは、preview後にsourceが変わった場合の安全境界として維持する。

ただしreader compatibilityは別問題である。h-kernel形式のreversalを追加した後もbqn-ledgerのreportやreaderをcanonical sourceへ向け続けるなら、BQN Journal admissionが`reverses`を読める必要がある。bqn-ledgerをcanonical readerとして使わないなら、その対応はcutover後の互換作業へ送れる。

BQN reader/editorを新contractへ対応させる場合は、少なくとも次が必要である。

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
- source format migration
- UI

既存のidentity-free BQN reversalを自動rewriteしない。historical source cleanupは別の明示的なprovenance migrationとしてのみ検討する。

## Cutover effect

このdecisionにより、editor cutover readinessのGate 6に対するdesired contractは確定するが、gate自体はまだSatisfiedではない。

残る条件:

- bqn-ledger readerをcutover後もcanonical sourceへ向けるか決める
- readerを残す場合は`reverses` admissionを対応させる
- private non-canonical copyでh-kernel reverseを一度確認する
- canonical writerをBQNからh-kernelへ切り替える操作手順を決める

cross-process shared lock、dual-editor alternating write rehearsal、lock contention testはsingle-user cutover gateから除外する。

Gate 8のsemantic comparisonでは、Actual reverseのexpected resultを「現在の差を受容する」から「canonical contractへ収束させる」に更新する。

## Daily-use cutover target

日常利用を`bqn-ledger`から`h-kernel`へ切り替える条件は、BQN editorの全operationを移植することではない。次の二本柱が揃うこととする。

1. Haskell editorが、日常的に必要なsource writeをpreview、strict admission、stale rejection付きで実行できる。
2. `bqn-ledger`の`tools/bl`に相当する一つのcommand hubが、report、editor、check、helpなど既存ownerへの入口をまとめる。

command hubは会計計算やsource mutationを再実装しない。小さなdoorwayとして既存の`h-kernel` report executable、`h-kernel-editor-cli`、repository checksへ引数を渡す。

```text
one daily command
  -> report
  -> edit
  -> check
  -> help
```

この二本柱をnon-canonical copyで一度確認した後、日常入口を`h-kernel`へ切り替える。BQN-only maintenance operation、historical cleanup、完全なsource migrationは、日常切替より後へ送れる。

## Next finite slice

次はh-kernel daily command hubの最小実装とする。

有限な問い:

> accounting、editor、checkの意味を複製せず、既存ownerへ委譲する一つのdaily-use入口を作れるか。

最初のsurfaceは次に限定する。

- default report
- editor CLIへの委譲
- repository checkへの委譲
- help
- direct subcommand operation

次sliceでは次を混ぜない。

- reverse implementation change
- bqn-ledger parser change
- interactive full-screen TUI
- source migration
- private source rehearsal
- canonical writer cutover