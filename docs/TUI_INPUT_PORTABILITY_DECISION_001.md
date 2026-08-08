# TUI input portability decision 001

ステータス: current contract  
Owner: h-kernel editor TUI input delivery  
更新日: 2026-08-08

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

### Ordinary Actual

```text
Actual workspace
  -> a
  -> Amount
  -> Description
  -> Category
  -> Pay from
  -> Date
  -> Enter: Preview
  -> Enter: Publish
```

TodayはDateの初期値である。別日付はDate fieldを直接編集する。Account名も通常のtext fieldから入力できるため、Account picker shortcutは必須ではない。

### Multi-posting Actual

```text
Actual workspace
  -> m
  -> Date
  -> Description
  -> Posting count
  -> selected Account
  -> selected Amount
  -> Up/Down: selected posting row
  -> Enter: Preview
  -> Enter: Publish
```

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
