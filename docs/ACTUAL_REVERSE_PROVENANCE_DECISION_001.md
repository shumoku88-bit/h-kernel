# Actual reverse durable provenance contract

ステータス: 承認済みcurrent contract  
Owner: Actual reversal identity and provenance  
更新日: 2026-08-17

## 1. Reversal law

Actual reverseは元Transactionを変更または削除せず、Actual Journalへ一つの新しいTransactionを追加する。

1. 元Transactionの全Postingを、順序とCommodityを保ったままexactに反転する。
2. reversal Transactionは新しいdurable `event-id`を持つ。
3. reversal Transactionは`reverses` metadataでtargetのdurable Actual identityを明示する。
4. unknown target、self-reference、duplicate reversal identityを拒否する。
5. 同じtargetを直接二回reverseしない。
6. reversal Transaction自身を、別の新しいTransactionでreverseすることは許可する。
7. description、amount、date、Account shapeからtarget relationを推測しない。

最小source shapeは次である。

```journal
YYYY-MM-DD description
  ; event-id: NEW-REVERSAL-ID
  ; reverses: TARGET-ACTUAL-ID
  account:a  INVERSE-AMOUNT COMMODITY
  account:b  INVERSE-AMOUNT COMMODITY
```

raw indentation、status marker、descriptionはsemantic identityではない。`event-id`、`reverses`、admitted Transactionが意味を所有する。

## 2. Explicit provenance

reversalは「反対符号の似た取引」ではなく、「どのActual factを否定したか」というexplicit provenance relationである。

このrelationによりsource admissionは次を検証できる。

- target identityが存在する
- reversal identityが一意である
- targetとreversalが同一identityではない
- direct duplicate reversalがない
- reverse-of-reverseが別のexplicit relationとして表現される
- description変更や同額Transactionの存在に依存しない

`[reverse]`のようなdescription conventionだけをtarget relationとして扱わない。

## 3. Current implementation ownership

`HKernel.Editor.ActualReverse`はtyped target identityとnew reversal identityからinverse postingsを持つcandidateを準備し、complete sourceをstrict admissionへ戻す。

`HKernel.Actual.Journal`は`event-id`と`reverses`をtyped projectionとしてadmitし、identity / relation invariantを検証する。

UI、CLI、shell launcherはreversal identity ruleを再実装しない。writer publication lawとcanonical writer authorityはこの文書のownerではない。

## 4. Reader compatibility boundary

canonical `actual.journal`を読むimplementationは、`event-id`と`reverses`をrecognized metadataとしてadmitし、この文書のrelation lawをsilent ignoreしてはならない。

別readerの互換性のためにdurable identity、explicit target relation、duplicate rejectionを弱めない。reader compatibilityとwriter authorityは別に判断する。writer authorityのcutover / rollbackは[`WRITER_AUTHORITY.md`](WRITER_AUTHORITY.md)が所有する。

## 5. 境界

このcontractは次を変更しない。

- canonical writer authority
- private canonical sourceの配置
- Account / Plan / Envelope / Issue semantics
- source format migration policy
- Editor delivery implementation
- historical identity-free transactionの自動rewrite

過去のcutover手順、command hub導入状況、実装slice、完了済みcompatibility作業はcurrent contractへ保存せずGit履歴とmerged PRが所有する。
