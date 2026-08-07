# h-kernel TODO

このファイルは、作者とpitが同じ優先順位で作業するための単一の入口である。

- pitは作業開始時にこのファイルを最初に読み、最上位の未完了項目から一つの有限sliceを選ぶ。
- 実装の正確な契約は各owner文書とcode/testが所有する。このファイルへ設計詳細や作業日誌を増やさない。
- 完了は、操作例、focused test、必要な正データの非破壊確認で観察できた場合だけチェックする。
- 新しい計画文書を追加せず、必要なら既存文書を置換・統合・削除する。

## 目標

正データを直接編集するより、`h-kernel`のCLI/TUIから操作する方が速く、分かりやすく、安全な状態にする。正データと互換性を失った`bqn-ledger`のwriterへ日常操作を依存させない。

## P0: コマンドを信用できる状態にする

- [ ] 利用者が失敗したREADMEのmulti-posting入力を、実際の引数と正データ形式に沿って再現し、原因を固定する。
- [ ] `actual-multi`のsource path省略時に`--base` / `HKERNEL_LEDGER_DATA_DIR` / `ledger-data.local`から`actual.journal`を解決する。READMEの任意引数表記と実装を一致させる。
- [ ] `tools/hk help`に、コピーして使える完全な構文と例を各commandについて表示する。`[ARGS...]`や`...`だけで操作方法を隠さない。
- [ ] 全commandの検証表を作り、routeだけでなく実CLIのparse、preview、`--commit`、再admission、更新結果をsynthetic sourceでend-to-end testする。
  - [ ] workspace / `actual-add`
  - [ ] `actual-multi`（3件以上のPostingを含む）
  - [ ] `actual-reverse`
  - [ ] `account`
  - [ ] `plan add` / `plan finish`
  - [ ] `budget`
  - [ ] `issue`
  - [ ] report commands
  - [ ] `check` / `help` / invalid input
- [ ] standard testが成功しても日常commandが壊れたままにならないよう、上記end-to-end testを`cabal test all`または`tools/hk check`へ接続する。
- [ ] private正データの内容を出力せず、read/admissionを確認する。write確認は正データそのものではなく明示的な非canonical copyで行う。

現時点の証拠:

- explicit journal pathを指定した3 Postingの`actual-multi` previewはsynthetic journalで成功した。
- 現在の`tools/verify_daily_command_hub.py`は主に引数転送をstubで確認しており、editor CLIによるpreview/commitまでは確認していない。
- READMEは`actual-multi [ACTUAL_JOURNAL]`と読めるが、現在のrouterはpathを省略補完しない。

## P1: 日常UIを直接編集より便利にする

- [ ] 日常頻度の高い操作と、直接編集している理由（入力数、探索、修正、確認、待ち時間）を短く観察し、操作時間を改善基準にする。
- [ ] TUIの起動後に、利用可能な操作、key、現在のsource、失敗理由、次にできることが画面から分かるようにする。
- [ ] native multi-posting Actual addをTUIから行えるようにする。Postingの追加・削除・並べ替え・balance確認を入力中に行えるようにする。
- [ ] Actual reverseを一覧から選択してpreviewできるようにし、event IDの手入力を日常経路から外す。
- [ ] Account、Plan、Budget、Issue、Reportへ一つの日常入口から到達できるようにする。
- [ ] CLIも二級UIとせず、default source解決、対話補助、明確なdiagnostic、shell completionにより単発操作を快適にする。
- [ ] TUI/CLIのどちらから操作しても同じtyped operation、admission、preview、safe writerを使う。

UIの完了条件は「screenが存在する」ことではない。作者が正データの直接編集を選ぶ主な理由がなくなり、失敗時に修復方法が分かることとする。

## P2: 正データの全writerをh-kernelへ移す

`bqn-ledger`は正データとの互換性を失っており、reader、writer、fallbackとして使わない。未対応operationは明示的な手編集として扱い、sourceごとにpreview、complete-source admission、backup、atomic publication、post-admissionを確認してh-kernelへ移す。

- [ ] 現在の正データsourceごとに「読める / 書ける / 日常操作がある / 手編集が必要」を内容非公開で確認する。
- [ ] Account metadata writerをh-kernelへ移す。
- [ ] Plan add / finish / edit writerをh-kernelへ移す。
- [ ] Budget movementとBudget policy writerをh-kernelへ移す。
- [ ] Issue writerをh-kernelへ移す。
- [ ] Household / Report / application configurationのtyped writerを用意する。
- [ ] 各cutover後に、該当する`bqn-ledger` writer依存と互換説明を削除する。

## P3: 文書を圧縮する

- [x] 完了済みreview、BQN観察記録、将来adapter設計、重複code mapをGit履歴へ戻した。
- [x] `README.md`を現在のbuild・command・format・safetyへ絞った。
- [x] `AGENTS.md`をこのTODOと必要なcontractへの短い入口へ絞った。
- [x] Editorとsource migrationの現在地をそれぞれ一つのownerへ統合した。
- [ ] 残るdomain/report文書は、対象codeを変更するsliceで重複部分を継続的に削る。
- [ ] 文書削減後も`repository-audit`でリンク、index、正規ownerを検証する。

## 作業順

1. P0で壊れた・分かりにくいcommandを再現可能にする。
2. commandの安全性をtestで固定してからP1のUIへ接続する。
3. P2はsourceごとに有限sliceで進める。
4. P3は実装と別sliceで行い、以後の文書増殖を止める。
