# h-kernel Editor

ステータス: アクティブ
Owner: editorの現在能力、共通write境界、daily UIの制約

優先順位と未完了作業は[`../TODO.md`](../TODO.md)が所有する。この文書へphase履歴やbranch記録を蓄積しない。

## 目的

正データの直接編集より速く、分かりやすく、安全に日常操作を完了できるEditorを提供する。`bqn-ledger`は現在の正データに対するreader、writer、fallbackとして使わない。

## Components

```text
h-kernel-editor
  typed intent
  candidate preparation
  complete-source admission
  safe publication
  UI-independent interaction/query

h-kernel-editor-cli
  argv、preview、--commit、exit status

h-kernel-editor-tui
  Brick state、input、navigation、rendering、effect delivery

tools/hk
  source root resolutionと既存executableへのrouting
```

CLIとTUIはAccount、Money、Transaction、Journal、Plan、Budget、Issueの意味を再実装しない。

## Current operations

- Actual ordinary append
- Actual multi-posting append
- Actual reversal
- Account declaration append
- Budget movement append
- Household Issue append
- Plan add
- Plan finish

operationがcodeに存在することと、日常利用に十分なことは別である。全commandのparse、preview、commit、post-admissionをend-to-endで確認するまで完成扱いにしない。

## Safe write boundary

```text
explicit source
  + typed intent
  -> candidate fragment
  -> candidate complete source
  -> stable admission
  -> preview
  -> explicit commit
  -> stale-safe publication
```

safe writerはstale rejection、backup、sibling temporary file、atomic publication、post-admission、restore-capable failureを所有する。adapterはこの処理を複製しない。

## Daily UI

日常入口は`tools/hk`である。

- no args: Actual workspace TUI
- `report`: Report
- `actual-add`: Actual workspace
- `actual-multi`, `actual-reverse`, `account`, `plan`, `budget`, `issue`: explicit editor operation
- `check`: build、test、repository audit

TUIの完成条件はscreenやnavigation ADTの存在ではない。

- 利用可能な操作とkeyが画面から分かる
- sourceとvalidation failureが分かる
- multi-postingを追加・削除・確認できる
- reverse targetを一覧から選べる
- write前にpreviewとconfirmationがある
- 成功後にfresh sourceを再読込する
- 直接編集より少ない手数で日常操作を完了できる

Brick以外の将来adapterを理由に共通抽象を追加しない。二つ以上の実在adapterで共有されるか、domain invariantまたはwriter safetyを型で守る場合だけ共有層へ置く。

## Dependency

```text
h-kernel-editor -> h-kernel + h-kernel-household
editor CLI/TUI  -> h-kernel-editor
tools/hk        -> existing executable
```

逆方向の依存、UI toolkit型のshared libraryへの流入、shellでのdomain rule再実装を禁止する。

## Verification

```sh
cabal build all
cabal test all
cabal run exe:repository-audit
```

command usabilityとsource更新は、synthetic temporary sourceを使うend-to-end testで確認する。private sourceへのwrite確認は明示的な非canonical copyだけを使い、内容を出力しない。
