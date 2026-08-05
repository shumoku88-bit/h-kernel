# Actual editor semantic comparison 001

ステータス: E8b semantic comparison contract and synthetic harness  
Owner: cross-editor Actual candidate observation  
基準日: 2026-08-06  
基準 h-kernel main: `440e45a7cc4ca5d2ce1d703846f0e1d66755256d`  
基準 bqn-ledger main: `e35203c856ef27fed52dfe955825472104823198`

## Scope

このsliceは、E8a operation parity inventoryが次に定めたActual add / reverseのsemantic comparison contractを実装する。

- BQN implementationをHaskellへ移植しない
- BQN executableをh-kernel CIへ組み込まない
- 二つのeditorが独立して生成したcomplete candidate sourceを比較する
- strict Actual Journal admission後の意味を比較する
- public testは独立したsynthetic sourceだけを使う
- private canonical sourceへaccessしない
- canonical writer authorityを変更しない
- shared source-root lockをまだ実装しない
- source migration、Account、Plan、Budget、Issueを混ぜない

## Comparison shape

比較入力は三つのTextである。

```text
existing complete Actual source
BQN-produced candidate complete source
Haskell-produced candidate complete source
```

比較boundary自身はeditorを起動しない。候補の生成と比較を分離する。

```text
editor A intent
  -> candidate complete source A

editor B same intent
  -> candidate complete source B

existing + candidate A + candidate B
  -> h-kernel strict Actual admission
  -> added transaction observation
  -> semantic difference codes
```

これにより、BQN処理をHaskellへ写すことなく、両者が同じsource contractへ収束するかを観察できる。

## Structural admission contract

各candidateは次をすべて満たさなければ比較対象にならない。

1. existing sourceがstrict Actual Journalとしてadmitされる
2. candidate sourceがstrict Actual Journalとしてadmitされる
3. existing sourceのexact Textをprefixとして保持する
4. source末尾にnewlineを持つ
5. Account registryを変更しない
6. prior Transaction列を変更しない
7. Transaction数をちょうど一つ増やす
8. added durable identity projectionは0または1件だけ増える
9. added reversal projectionは0または1件だけ増える
10. reversal projectionが増える場合、そのreversal identityはadded transactionのidentityと一致する

failure resultはsource内容を保持しない。originとsanitised code、内部typeでは必要最小限の件数だけを保持する。

## Semantic coordinates

構造条件を通過したcandidateについて次を比較する。

| Coordinate | Observation owner | Meaning |
|---|---|---|
| Transaction | `HKernel.Ledger.Transaction` | date、description、posting order、Account、exact Quantity、Commodity |
| Actual identity | `HKernel.Actual.Journal` projection | added transactionのdurable `event-id`またはderived identity |
| reversal target | `ActualReversalDeclaration` | added reversalが明示的に否定するtarget identity |

raw Textの空白、status marker `*`、posting indentationは、それ自体ではsemantic differenceにしない。両candidateを同じstrict parserへ通し、admitted valueで比較する。

general metadataの全key/value、preview protocol、backup、stale token、atomic publish、shared lockはこのharnessの比較対象ではない。それぞれ別evidenceが必要である。

## Implementation boundary

`HKernel.Editor.ActualWriter`に次を追加する。

- `CandidateOrigin`
- sanitised `ActualComparisonError`
- `ActualSemanticDifference`
- `compareActualCandidateSemantics`
- stable error / difference code renderer

この位置は、candidate complete sourceとpost-admissionを既に所有するwriter boundaryの内側であり、BQN command grammarやJournal parserを複製しない。

focused synthetic harnessは既存`EditorActualWriterSpec`へ追加する。新しいtest runnerや外部runtime dependencyは増やさない。

## Current BQN Actual add observation

current `src_edit/journal_block_add_cmd.bqn`は、少なくとも次を行う。

- date、description、identity mode、Commodity、posting countをadmitする
- signed exact decimalをparseし、Commodity policy precisionを確認する
- zeroとunbalanced transactionを拒否する
- Accountを`accounts.tsv`へexact resolutionする
- complete existing Journalをadmitする
- candidate blockをrenderする
- proposed complete Journalを再admitする
- added candidateが期待したdate、description、posting、Commodity、identityに一致することを確認する

ordinary Actualではexplicit event-idを書かず、physical fallback identityとしてadmitされる。

## Current Haskell Actual add observation

`HKernel.Editor.ActualAppend.prepareActualAppend`は次を行う。

- existing Actual Journalをstrict parseする
- Account registryに対してpostingをresolveする
- zero、missing Commodity、undeclared Account、unbalanced transactionを拒否する
- exact Transaction blockをrenderする
- candidate complete sourceをstrict parse-backする

current CLIのordinary appendはexplicit `event-id`を受け取らない。

## Actual add finding

synthetic comparisonでは、次のraw rendering差があっても同じTransactionへ収束する。

- BQN headerのstatus marker `*`
- indentation幅
- Accountとamount間の空白幅

同じdate、description、ordered postings、exact Quantity、Commodityを持つordinary Actual addについて、parser-observable semantic coreは一致可能である。

このfindingはgeneral metadata parity、error taxonomy parity、writer IO parity、shared serializationを証明しない。

## Current BQN reverse observation

current BQN reverse pathは二段階である。

1. `journal_native_reverse_cmd.bqn`がindexまたはid/descriptionでtransactionを選び、inverse posting intentを出す
2. shell dispatcherが`[reverse]` descriptionを持つnative candidateを通常のJournal add pathへ渡す

current focused checkは次を期待する。

- source prefixを保持する
- postingをexactに反転する
- descriptionを`[reverse]...`とする
- existing `event-id`件数を増やさない

`journal_block_add_cmd.bqn`はdescriptionが`[reverse]`で始まるcandidateをderived transactionとして扱い、requested durable modeであってもeffective durable `event-id`を書かない。

current BQN reversal sourceには、h-kernelがtyped provenanceとして読む`reverses:` relationが書かれない。

## Current Haskell reverse observation

`HKernel.Editor.ActualReverse.prepareActualReverse`は次を要求する。

- targetがdurableまたはderived Actual identityで一意に見つかる
- new reversal identityが既存identityと重複しない
- targetが既に直接reverseされていない
- new transactionがtarget postingsのexact inverseである
- candidate blockにnew `event-id`を持つ
- candidate blockにexplicit `reverses` targetを持つ
- candidate complete sourceがstrict parse-backできる

## Actual reverse finding

posting、date、descriptionを同じにしたsynthetic candidateでも、current BQN candidateとcurrent Haskell candidateは次で一致しない。

```text
actual_identity_differs
actual_reversal_target_differs
```

これはraw formatting差ではなく、provenance semanticsの差である。

したがって、E8aでOverlap candidateとしたActual reverseを、current evidenceではinitial dual-editor pilotへ昇格できない。

## Revised pilot classification

| Operation | E8b result | Initial dual-editor status |
|---|---|---|
| Actual ordinary add | semantic core can converge | conditional candidate |
| Actual multi-posting add | same comparison lawを適用可能だがfocused scenario拡張が必要 | not yet opened |
| Actual reverse | identity / provenance mismatch | blocked |
| Budget add | not observed in this slice | pending |
| Issue add | not observed in this slice | pending |

Actual ordinary addも、shared source-root serialization、stale conflict、backup/restore、private non-canonical alternating rehearsalが完了するまでcanonical dual-editor writeを許可しない。

## Privacy boundary

comparison errorとdifference codeは次を出力しない。

- Account名
- date
- description
- Quantity
- Commodity
- event-id
- reverses target
- source Text
- file path
- parser diagnostic detail

public focused testはprivate sourceを変形せず、最初から独立したsynthetic Account、Transaction、identityを使う。

private non-canonical rehearsalでこのAPIを利用する場合も、success/failure code以外をstdout、CI、PR、Issueへ出さない。

## Gate effect

`EDITOR_CUTOVER_READINESS_AUDIT_001.md`のGate 1、6、8を次のように具体化する。

- Gate 1 operation parity
  - Actual ordinary addのsemantic core比較contractは実装済み
  - Actual reverseはcurrent mismatchを確認
- Gate 6 identity / provenance
  - ordinary addは両側ともexplicit identityを持たない
  - reverseはBQNとHaskellでidentity/provenanceが不一致
- Gate 8 bqn semantic comparison
  - executable pure comparison boundaryとfocused synthetic evidenceを追加
  - Actual全体のparityは未完了

いずれのgateも、このsliceだけではSatisfiedにならない。

## Next finite slice

次はActual reverse durable provenance decisionとする。

有限な問いは次である。

> initial dual-editor periodのreverseは、どのshared durable identityとexplicit provenance relationをcanonical contractにするか。

次sliceでは次を混ぜない。

- shared lock実装
- private source rehearsal
- Account / Plan migration
- Budget / Issue comparison
- UI redesign
- canonical writer cutover

Haskellのexplicit provenanceを弱めるか、BQN reverseへdurable identity / relationを加えるか、第三のshared contractを置くかを、synthetic sourceと既存public behaviorから決定する。
