# h-kernel 作業入口

このファイルは、`h-kernel`で作業するcoding assistantのための共通入口である。

## 作業前

1. remoteの最新`main` SHA、open PR、直近commit、関連branchを確認する。
2. 対象fileと並行作業の変更fileを比較し、実在する重複を避ける。
3. 対象領域のarchitecture、contract、source ownership文書と実コードを読む。
4. editorまたはwriter effectへ触れる場合は、[`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md)でcurrent capability、active roadmap、writer law、cutover gateを確認する。
5. private household sourceへ触れる場合は、writer authority、公開境界、実データが維持されることを先に確認する。

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

## 標準検証

```sh
cabal build all
cabal test all
cabal run repository-audit
```

Reportへ影響する場合は、必要なfocused testに加えて次を実行する。

```sh
./report-build
./report-verify --fixture
./report-verify --corpus
```

正規世帯sourceへ影響する場合は、private sourceの内容を出力せず追加検証する。

```sh
HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data ./report all >/dev/null
```

## 文書入口

- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): 作業手順と文書寿命
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): component、依存方向、会計不変条件、effect ownership
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editorのcurrent capability、roadmap、writer law
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): private canonical sourceとwriter authority
- [`docs/INDEX.toml`](docs/INDEX.toml): 稼働中の正規文書一覧
- [`SECURITY.md`](SECURITY.md): 公開データと秘密情報の境界
