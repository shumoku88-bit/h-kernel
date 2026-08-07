# Actual reversal contract

ステータス: アクティブ
Owner: Actual reversalのidentity、relation、admission

## Contract

Actual reversalは元Transactionを変更または削除せず、新しいinverse Transactionをappendする。

```journal
YYYY-MM-DD reversal description
  ; event-id: NEW-REVERSAL-ID
  ; reverses: TARGET-ACTUAL-ID
  account:a  INVERSE-AMOUNT COMMODITY
  account:b  INVERSE-AMOUNT COMMODITY
```

- reversal自身が新しいdurable `event-id`を持つ
- `reverses`でtarget identityを明示する
- Postingの順序とCommodityを保持してQuantityだけを反転する
- unknown target、self-reference、duplicate direct reversalを拒否する
- reverse-of-reverseは新しいexplicit edgeとして許可する
- description、日付、amount、Posting shapeからtargetを推測しない

## Owner

`HKernel.Actual.Journal`がActual identityとrelationをadmitする。`HKernel.Editor.ActualReverse`はtyped intentからcandidateを準備し、共通safe writerへ渡す。

CLI/TUIはidentity、inverse calculation、duplicate判定を再実装しない。

## Daily operation

現在のCLIはtarget identityを明示入力する。

```bash
./tools/hk actual-reverse \
  [--commit] \
  /absolute/path/to/actual.journal \
  NEW-EVENT-ID \
  TARGET-EVENT-ID \
  2026-08-06 \
  "correction description"
```

日常TUIではTransaction一覧からtargetを選び、新しいidentityを安全に生成できることを目標とする。完成まではCLIまたは明示的な正データ操作を使う。

## Writer law

reversalも通常のEditor write境界を迂回しない。

```text
intent -> candidate -> complete-source admission -> preview
       -> explicit commit -> stale-safe publication -> post-admission
```

`bqn-ledger`は現在の正規データに対するreader、writer、fallbackとして使用しない。互換adaptationや旧writerへのrollbackはこのcontractの対象にしない。
