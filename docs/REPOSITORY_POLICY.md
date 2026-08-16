# h-kernel リポジトリ運用方針

ステータス: 承認済み  
適用範囲: このリポジトリで行う設計、実装、検証、文書管理

## 1. 目的

このリポジトリは、実用できる家計簿を安全に育て、現在のdomain意味、source ownership、writer authority、検証根拠を少ない文書と明確なownerで維持する。

開発では次を守る。

- 会計上の意味を推測で作らない
- 一つのcoherent domain capabilityまたはmigration chapterを完成させる
- 作者とAIが同じ現在地と変更理由を把握する
- コードと文書を現在の実装へ同期させる
- 過去の文書を積み上げず、リポジトリを身軽に保つ

## 2. 標準の作業手順

1. 最新の`main`、open PR、関連branch、対象コード、正規データ、関連文書を確認する。
2. 今回end-to-endで完成させるdomain capabilityまたはmigration chapterを言葉にする。
3. 採用する方向、採用しない方向、semantic rollback boundary、非目標、検証方法を確認する。
4. 一つのcoherent changeを持つbranchとDraft PRで作業する。
5. 実装、focused test、full test、repository audit、必要なreport contract検証を行う。
6. 最終差分を、合意した範囲と維持すべき意味に照らして確認する。
7. 変わった現在の契約、現在地、運用方法だけを文書へ反映する。
8. 不要になった文書、節、参照、互換説明を同じ作業内で削除する。
9. Ready化とmergeの前に、正規データ、並行作業、既存contractを壊していないことを再確認する。

設計上の前提やsemantic rollback boundaryが途中で変わった場合は、別種のmigrationやauthority changeまで惰性で広げない。

## 3. 作業単位とsemantic rollback boundary

デフォルトの作業単位は、実装詳細ではなく、一つのuser value、domain capability、またはmigration chapterをend-to-endで完成させるcoherent changeである。

functionやmodule、parserとoperation、readerとwriter、test fileが別であることだけを理由に分割しない。同じdomain capabilityを成立させるcorrectness、ownership、algorithm、admission、writer effectが不可分なら一つのchangeに含める。

一方、次は原則として別chapterにする。

- domain semantic change
- source format migration
- writer authority cutover
- destructive retirement / deletion
- 無関係なrenderer / UI redesign

PRの小ささを安全性の代理指標にしない。安全性はdomain type、明示的ownership、invariant、focused regression、full test、CI、repository audit、final diff review、rollback clarityで確保する。

既存PRの境界は将来の設計境界ではない。不自然なstackになっている場合は`consolidate`、`supersede`、`rebase`、`reconstruct`を選んでよい。

## 4. 文書の言語

人間が読むリポジトリ文書は日本語を正本とする。

Haskellの識別子、module名、型名、関数名、file path、CLI command、外部資料の原題は翻訳しない。code block内の構文も原文を保つ。

新規文書と更新部分は日本語で書き、意味を確認しながら現在の契約へ同期する。

## 5. 文書は現在を所有する

文書は現在の設計、契約、roadmap、運用方法を説明する。過去の状態はGit履歴、merged PR、commitが所有する。

次を標準とする。

- 一つの意味には一つの正規ownerを置く
- 同じ説明をREADMEと複数のdesign noteへ重複させない
- 完了した移行手順や復元計画は、現在の契約でなければ削除する
- 新しい文書を追加する前に、既存ownerを更新できないか確認する
- 新しい文書が既存文書を置き換える場合、置き換えられた文書を同時に削除する
- historical snapshot、完了済みroadmap、作業ログ、互換性の記念碑を通常文書として保存しない
- `archive/`を文書の捨て場所として作らない

`observation`文書は、**まだ閉じていない具体的な設計上の問い**があり、その問いを解くための証拠を現在進行形で所有するときだけ置く。問いが閉じたら、将来も必要なlawだけをcurrent contract / architecture ownerへ反映し、観察記録そのものは同じchangeで削除する。

日付、baseline SHA、完了済みPR一覧、実装sliceの作業記録、closed gateの検証表はcurrent authorityではない。それらを参照する必要がある場合はGit履歴とmerged PRを使い、`docs/INDEX.toml`のactive documentへ残さない。

削除は現在の理解を一つに保ち、過去をGit履歴へ戻すための通常の保守である。

## 6. 作業完了時の文書確認

- public APIまたはdomain ownerが変わった場合、その現在のowner文書を更新する
- source、policy、report contract、writer authorityが変わった場合、その正規文書を更新する
- roadmap上の現在地が移動した場合、現在地を更新する
- 文書変更が不要な場合は、現在の文書が引き続き正しいことを確認する
- 古くなった説明を見つけた場合、安全に削除できる範囲を同じchangeで削除する
- `observation`の問いが閉じた場合、その文書をactive setから削除する

文書を増やすことは完了条件ではない。現在の意味を少ない文書で正確に保つことが完了条件である。

## 7. コードとアーキテクチャ

全体の依存方向とdomain invariantは[`ARCHITECTURE.md`](ARCHITECTURE.md)、report計算の境界は[`REPORT_PIPELINE_POLICY.md`](REPORT_PIPELINE_POLICY.md)、editorのactive roadmapは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)に従う。

新しい抽象やdependencyは、Haskellで可能だからではなく、実在するdomain問題、重複、correctness、operational costを改善する場合だけ導入する。

## 8. 正規データとwriter authority

別private repositoryにある正規データ、writer authority、公開境界は、関連するsource migrationとsecurity policyに従う。

private sourceをpublic checkout、fixture、CIへcopyしない。設計整理や文書削除を理由に、正規データ、writer-owned compatibility source、private history、backupを独断で変更しない。
