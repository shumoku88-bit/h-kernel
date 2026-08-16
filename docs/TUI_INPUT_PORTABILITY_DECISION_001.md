# TUI input portability decision 001

ステータス: current contract  
Owner: h-kernel editor TUI input delivery  
更新日: 2026-08-16

## Decision

`h-kernel-editor-tui`の日常操作は、Function key、Ctrl-modified key、terminal-specific prefix sequenceを必要条件にしない。

日常workflowは次の入力だけで完了可能でなければならない。

- ordinary text input
- ordinary unmodified character keys used outside text entry
- Enter
- Esc
- Tab
- arrow keys

Function keyやCtrl-modified keyを将来補助shortcutとして追加する場合でも、それだけがoperationへ到達する経路になってはならない。

## Why

実運用terminal環境では、F-keyとCtrl-modified keyがBrick/Vty applicationへ期待どおり届かないことが確認された。

terminal emulator、multiplexer、shell、IME、remote sessionなどのdelivery差を日常会計operationの到達可能性へ持ち込まない。

このdecisionはterminal key encodingを一般化する試みではない。操作に必要なkey contract自体を小さくする。

## Current daily input shape

### Daily Actual shortcuts

日常的な単純支出と収入には、一般Recordより短い入口を残す。

```text
Actual workspace
  -> a: Expense
     or i: Income
  -> Amount
  -> Description
  -> typed Account fields
  -> Date
  -> Enter: Preview
  -> Enter: Publish
```

TodayはDateの初期値である。別日付はDate fieldを直接編集する。Account名も通常のtext fieldから入力できるため、Account picker shortcutは必須ではない。

`a`と`i`は一般記帳とは別のaccounting modelではない。頻度の高い2-posting操作への短いdelivery pathである。

### General Record

ordinary transactionと3-posting以上のtransactionを別modeへ分けない。一般記帳は一つのRecord flowを使う。

```text
Actual workspace
  -> r
  -> Date
  -> Description
  -> Posting count
  -> selected Account
  -> selected Amount
  -> Up/Down: selected posting row
  -> Enter: Preview
  -> Enter: Publish
```

Recordは2つのblank posting rowから始まり、必要ならPosting countを増やす。同じflowのまま2-posting transactionも3-posting以上のtransactionも記帳する。multi-posting専用のTUI modeや専用shortcutを必要条件にしない。

Posting countを通常fieldとして編集できるため、row add/remove専用Function keyを必要としない。Accountも通常fieldから入力できる。

Transaction balance、Account admission、Commodity resolutionは従来どおりshared editor/domain ownerが検証する。TUIはこれらを再実装しない。

### Plan Complete & Advance

Actual date、Actual amount、successor date、successor amountは既存form fieldを直接編集する。Today/Yesterday用Function keyまたはCtrl shortcutを必要としない。

### Reports and workspace navigation

workspaceのplain character key、Tab、Enter、Esc、arrow、j/kによる既存navigationを使う。修飾keyをdaily completionの必要条件にしない。

## Ergonomic law

入力補助は、入力可能性そのものと分離する。

```text
required path = portable ordinary keys
optional aid  = may exist only when required path remains complete
```

候補pickerやshortcutを将来再導入する場合は、Tab + Enterなどportable pathからも同じ機能へ到達できることを条件とする。

portableであることは、候補選択や発見可能性を捨てる理由ではない。Accountなど既知のcanonical candidateを持つfieldでは、直接text入力を常に残した上で、ordinary keysだけから候補browse/searchへ到達できるergonomic aidを別sliceで追加してよい。候補pickerは入力の唯一経路にせず、手打ちを強制する唯一経路にも固定しない。

## Boundaries

このdecisionは次を変更しない。

- accounting semantics
- Account identity semantics
- Transaction balance rules
- Actual reversal identity / provenance
- Plan recurrence semantics
- source format
- writer authority
- private canonical source
- safe writer / stale-source rejection

Actual reversal workspaceを含む今後のTUI input chapterも、このportable input contractに従う。
