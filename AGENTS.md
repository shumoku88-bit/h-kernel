# h-kernel 作業入口

このファイルは、`h-kernel`で作業するcoding assistantのための共通入口である。

## 家計相談と開発を最初に分ける

依頼がHouseholdの支出、残高、予定、Issue、Envelope、過去の判断などについての**家計相談**なら、通常のrepository開発手順へ入らない。read-only concierge modeとして扱い、Household evidenceは次だけから取得する。

```sh
tools/hk concierge overview
```

追加のsource evidenceが必要な場合だけ`tools/hk concierge export`、一度にcomplete observationが必要なら`tools/hk concierge packet`を使う。consultation中に`actual-add`、`actual-multi`、`actual-reverse`、`account`、`plan`、`budget`、`issue`、`edit`を呼ばない。日付、memo、金額、Account shape、source positionの類似からidentityやrelationを推測しない。

相談の結果として実際のHousehold変更を依頼された場合は、consultation modeを終了したことを明示してから、通常のadmitted writer workflowへ切り替える。助言とwriter effectを一つの暗黙経路に混ぜない。

依頼がrepository、code、architecture、test、CI、writer実装そのものについてなら、以下の通常の開発手順を使う。

## 作業前

1. remoteの最新`main` SHA、open PR、直近commit、関連branchを確認する。
2. 対象fileと並行作業の変更fileを比較し、実在する重複を避ける。
3. 対象領域がまだ広い場合は、`tools/hk context TERM`でcurrent source、test、active documentの候補を絞る。componentと公開境界の全体像が必要な場合だけ`tools/hk map`を見る。
4. 対象領域のarchitecture、contract、source ownership文書と実コードを読む。
5. editorまたはwriter effectへ触れる場合は、[`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md)でcurrent capabilityとsafe writer law、[`docs/WRITER_AUTHORITY.md`](docs/WRITER_AUTHORITY.md)でsource別authorityとcutover gateを確認する。
6. private household sourceへ触れる場合は、[`docs/HOUSEHOLD_CANONICAL_SOURCE.md`](docs/HOUSEHOLD_CANONICAL_SOURCE.md)でcanonical source shapeとcurrent reader topologyを確認し、writer authority、公開境界、実データが維持されることを先に確認する。

`tools/hk map`と`tools/hk context`の出力は、`h-kernel.cabal`、Haskell source、test、`docs/INDEX.toml`からその場で作る探索viewであり、設計上のauthorityではない。出力を文書として保存したり、別の手書き目録へ転記したりしない。

## 判断基準

設計や実装は、言語機能を見せることではなく、h-kernelで実在する問題を正確かつ簡潔に解くために選ぶ。

実装前に必要な範囲で次を確認する。

- 今回成立させるuser value / domain capability / migration chapterは何か
- canonical ownerと既存lawはどこか
- identity、provenance、exact arithmetic、source ownership、writer safetyへ影響するか
- invalid stateや失敗条件は何か
- pure calculationとeffect boundaryはどこか
- 既存の型と小さな名前付き関数で十分か
- 新しい抽象やdependencyは、実在する重複や問題を本当に減らすか
- focused test、full test、CI、final diffで何を証明するか

特定のHaskell機能、抽象度、短さ、LOC削減を目標にしない。domainに不要なframeworkやgeneric abstractionを持ち込まない。

## 作業単位

- デフォルトは、一つのuser value、domain capability、またはmigration chapterをend-to-endで完成させるcoherent changeとする。
- function、module、reader/writer、parser/operation、test fileが別であることだけを理由に分割しない。
- correctness、ownership、algorithm、admission、writer effectが同じdomain capabilityを成立させるため不可分なら、一つのchangeに含めてよい。
- domain semantic change、source format migration、writer authority cutover、destructive retirement、無関係なpresentation redesignは原則として別に扱う。
- 既存PRの境界を次の設計境界として自動継承しない。必要ならconsolidate、supersede、rebase、reconstructする。
- 変更後に不要になった説明、互換入口、古いスケッチは同じcoherent changeで削除する。

詳細な運用は[`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md)に従う。

## 探索入口

repository全体のcomponent、public/internal module、test-suite、active document ownershipを現在の正本から見る。

```sh
tools/hk map
```

特定のmodule、型、関数、domain語から、直接言及するsource、test、documentを絞る。

```sh
tools/hk context HKernel.Envelope.Remaining
```

これは検索開始点を狭くするためのviewであり、依存関係や意味論を推測して補完するものではない。必要なownerへ到達した後は、実コード、型、export、contractを正本として読む。

## 標準検証

通常のrepository qualificationは次の一つを入口とする。

```sh
tools/hk check
```

Reportへ影響する場合は、必要なfocused testに加えて次を実行する。

```sh
tools/hk check-report
```

正規世帯sourceへ影響する場合は、private sourceの内容を出力せず次を追加実行する。

```sh
tools/hk --base /absolute/path/to/private-ledger-data check-household
```

`cabal`、`report-*`、verification scriptの個別呼び出しはCIやtool実装を調査するときだけ使い、通常作業の入口として重複させない。

## 文書入口

- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): 作業手順と文書寿命
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、依存方向、会計不変条件、effect ownership
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editorのcurrent capability、roadmap、safe writer law
- [`docs/HOUSEHOLD_CANONICAL_SOURCE.md`](docs/HOUSEHOLD_CANONICAL_SOURCE.md): canonical Household source shapeとcurrent reader topology
- [`docs/WRITER_AUTHORITY.md`](docs/WRITER_AUTHORITY.md): source別writer authorityとcutover gate
- [`docs/AI_CONCIERGE.md`](docs/AI_CONCIERGE.md): read-only Household consultation protocolと開発/writer境界
- [`docs/INDEX.toml`](docs/INDEX.toml): 稼働中の正規文書一覧
- [`SECURITY.md`](SECURITY.md): 公開データと秘密情報の境界
