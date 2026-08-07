# h-kernel リポジトリ運用方針

ステータス: 承認済み  
適用範囲: このリポジトリで行う設計、実装、検証、文書管理

## 1. 目的

このリポジトリは、実用できる家計簿を育てながら、Haskellの型、純粋関数、データ変換、所有権の境界をコードから学べる状態を保つ。

開発速度だけでなく、次を同時に守る。

- 会計上の意味を推測で作らない
- 一度に一つのcoherent domain capabilityまたはmigration chapterを完成させる
- 作者とAIが同じ現在地と変更理由を把握する
- コードと文書を現在の実装へ同期させる
- 過去の文書を積み上げず、リポジトリを身軽に保つ

## 2. 標準の作業手順

すべての作業は、原則として次の順序で進める。

1. 最新の`main`、open PR、関連する並行branch、対象コード、正規データ、関連文書を確認する。
2. ロードマップ上の現在地と、今回end-to-endで完成させるdomain capabilityまたはmigration chapterを言葉にする。
3. 設計の候補、採用する方向、採用しない方向、semantic rollback boundary、非目標、検証方法を作者とAIで合意する。
4. 一つのcoherent changeを持つbranchとDraft PRで作業する。
5. 実装、focused test、full test、repository audit、必要なreport contract検証を行う。
6. 最終差分を、合意した範囲と維持すべき意味に照らして確認する。
7. 作業で変わった現在の契約、現在地、運用方法を文書へ反映する。
8. 変更によって不要になった文書、節、参照、互換説明を同じ作業内で削除する。
9. Ready化とmergeの前に、正規データ、他の作業、日本語文書を壊していないことを再確認する。

設計上の前提やsemantic rollback boundaryが途中で変わった場合は、そのまま別種のmigrationやauthority changeまで広げず、作者とAIの合意へ戻る。

## 3. 作業単位とsemantic rollback boundary

デフォルトの作業単位は、実装詳細ではなく、一つのuser value、domain capability、またはmigration chapterをend-to-endで完成させるcoherent changeである。

次の違いだけを理由にPRやbranchを分けない。

- functionやmoduleが異なる
- parserとoperationが異なる
- readerとwriterが異なる
- pure logicとそのfocused testが異なるfileにある
- 同じdomain capabilityを成立させるcorrectness、ownership、algorithm、admission、writer effectが複数ownerへまたがる

同じ失敗で一緒にrollbackしたい変更は、原則として同じcoherent changeに含める。

一方、次は意味とrollback条件が異なるため、原則として別のchapterにする。

- domain semantic change
- source format migration
- reader cutover。ただしsource migrationと不可分で明示的に同時実施する場合を除く
- writer authority cutover
- destructive retirement / deletion
- 無関係なrenderer / UI redesign

小さいこと自体を目的にはしない。PRの小ささを安全性の代理指標にしない。安全性は、strong domain type、明示的ownership、invariant、focused regression、full test、CI、repository audit、final diff review、rollback clarityで確保する。

既存PRの境界は将来の設計境界ではない。現在の完成形に対して不自然な分割になっている場合は、`consolidate`、`supersede`、`rebase`、`reconstruct`を選んでよい。

並行作業とのconflict avoidanceは、実際に並行作業が存在する場合だけ制約として扱う。停止済みまたは存在しない並行作業を仮定して作業を細分化しない。

作業を分割する前に、次を確認する。

> この分割はdomain architectureまたはrollback boundaryを明確にするか。それとも作業管理の都合だけで短命な中間状態を増やすか。

後者なら分割しない。

## 4. 文書の言語

人間が読むリポジトリ文書は日本語を正本とする。

対象には次を含む。

- `README.md`
- `docs/`以下の文書
- private household sourceの運用文書とtest corpusの説明文書
- Pull RequestとIssueの説明

Haskellの識別子、module名、型名、関数名、file path、CLI command、外部資料の原題は翻訳しない。code block内の構文も原文を保つ。

新規文書と更新部分は日本語で書く。既存文書を機械的な一括置換で直すのではなく、意味を確認しながら現在の契約へ同期する。

## 5. 文書は現在を所有する

文書は、現在の設計、現在の契約、現在のロードマップ、現在の運用方法を説明する。

過去の状態はGit履歴、merged PR、commitが所有する。リポジトリ内の通常文書へ作業日誌を蓄積しない。

次を標準とする。

- 一つの意味には一つの正規ownerを置く
- 同じ説明をREADME、コードスコア、複数のdesign noteへ重複させない
- 完了した移行手順や復元計画は、現在の契約でなければ削除する
- 新しい文書を追加する前に、既存ownerを更新できないか確認する
- 新しい文書が既存文書を置き換える場合、置き換えられた文書を同時に削除する
- historical snapshot、完了済みroadmap、作業ログ、互換性の記念碑を通常文書として保存しない
- `archive/`を文書の捨て場所として作らない

削除は情報を失うことではない。現在の理解を一つに保ち、過去をGit履歴へ戻すための通常の保守である。

## 6. 作業完了時の文書確認

コード作業の完了条件には、文書影響の確認を必ず含める。

- public APIまたはdomain ownerが変わった場合、その現在のowner文書を更新する
- source、policy、report contract、writer authorityが変わった場合、その正規文書を更新する
- ロードマップ上の現在地が移動した場合、現在地を更新する
- 文書変更が不要な場合は、現在の文書が引き続き正しいことを差分確認で確かめる
- 古くなった説明を見つけた場合、別のTODOとして積むだけでなく、今回のcoherent changeで安全に削除できる範囲を削除する

文書を増やすことは完了条件ではない。現在の意味を少ない文書で正確に保つことが完了条件である。

## 7. コードとアーキテクチャ

Haskellコードの形は[`HASKELL_NATIVE_CODE_POLICY.md`](HASKELL_NATIVE_CODE_POLICY.md)、report計算の境界は[`REPORT_PIPELINE_POLICY.md`](REPORT_PIPELINE_POLICY.md)、全体の依存方向は[`ARCHITECTURE.md`](ARCHITECTURE.md)に従う。

この文書は、それらのdomain policyを重複して説明しない。リポジトリ全体の作業方法と文書寿命だけを所有する。

## 8. 正規データとwriter authority

別private repositoryにある正規データ、writer authority、公開境界は、関連するsource migrationとsecurity policyに従う。

private sourceをpublic checkout、fixture、CIへcopyしない。設計整理や文書削除を理由に、正規データ、writer-owned compatibility source、private history、backupを独断で変更しない。
