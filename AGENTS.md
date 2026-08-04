# h-kernel 作業入口

このファイルは、`h-kernel`で作業するcoding assistantのための共通入口である。特定のtoolやassistantに固有の設計規則は置かず、リポジトリ自身が所有する文書と検証へ案内する。

## 作業前

1. remoteの最新`main` SHA、open PR、直近commit、関連branchを確認する。
2. 対象fileと並行作業の変更fileを比較し、重複を避ける。
3. [`docs/CODE_MAP_AND_DESIGN_SKETCH.md`](docs/CODE_MAP_AND_DESIGN_SKETCH.md)で、リポジトリ全体の現在の編成と設計スケッチを確認する。
4. 対象領域のpolicy、architecture、contract、source ownership文書を読む。
5. editorまたはwriter effectへ触れる場合は、[`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md)でmain能力、NEXT、並行path、cutover gateを確認する。
6. private household sourceへ触れる場合は、writer authority、公開境界、実データが維持されることを先に確認する。

## コードスコアの読み方

コードスコアは、全体の関係を眺め、これからの構成を下書きするための面である。個別の厳密な契約を置き換えない。

- `CURRENT`: `main`に存在する現在の状態
- `DIRECTION`: 作者と合意した育てる方向
- `SKETCH`: 未決定の案
- `QUESTION`: 証拠または判断が不足している問い

`SKETCH`を決定済み仕様として実装しない。component、domain ownership、主要data flow、全体の方向が変わる作業では、実装とコードスコアを同じsliceで同期する。局所変更だけで全体が変わらない場合は、機械的な追記をしない。

## 実装前の二重譜読み

Haskell codeを変更するsliceでは、coding assistantは唯一の作曲者として振る舞わない。対象domainの正規owner、作者との合意、現在の型とtestを譜面として読み、その意味をHaskellの形で演奏する。

実装前に、少なくとも次を短く示す。

```text
Domain phrase:
Domain structure:
Haskell phrase:
Correspondence:
Rejected phrases:
Evidence:
```

- `Domain phrase`: 今回の変換または法則をdomainの一文で表す
- `Domain structure`: 事実、policy、導出値、不変条件、失敗、粒度、順序や時間の意味を分ける
- `Haskell phrase`: 型、ADT、pattern matching、合成、検証、fold、effect boundaryなど、採用する書法を示す
- `Correspondence`: その書法がdomainの何を見せ、どのinvalid state、branch、重複、手続き的状態を減らすかを示す
- `Rejected phrases`: 検討したがdomainに合わない書法と、その理由を示す
- `Evidence`: example、focused test、property、law、既存contractなど、対応を観察する方法を示す

これは新しいHaskell機能を毎回導入するためのchecklistではない。既存の型と小さな名前付き関数が最もよくdomainを表す場合は、それが採用する音である。逆に、高度な機能がdomain構造を正確に表す場合は、初見であることだけを理由に避けない。

同じdomainの意味には同じownerとlawを使う。異なるdomainまで同じ書法へ機械的に揃えない。実装中に新しい順序、identity、effect、失敗条件が現れた場合は、そのまま編曲を広げず、作者との設計合意へ戻る。

詳細は[`docs/HASKELL_NATIVE_CODE_POLICY.md`](docs/HASKELL_NATIVE_CODE_POLICY.md)に従う。

## 作業単位

- 一度に一つの有限な目的だけを扱う。
- correctness、ownership、algorithm、source format、presentation、writer effect、文書構造の変更を無関係に混ぜない。
- 既存の事実、policy、導出値、presentationを区別する。
- Account名、残高、file配置から会計上の意味を推測しない。
- 未合意の設計案を、抽象の導入理由やcleanupの口実にしない。
- 変更後に不要になった説明、互換入口、古いスケッチは同じsliceで剪定する。

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

正規世帯sourceへ影響する場合は、private sourceを明示し、内容を出力せず追加検証する。

```sh
HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data ./report all >/dev/null
```

変更範囲に応じて、Report contract、snapshot、複数compilerのCIも確認する。

## 文書入口

- [`docs/CODE_MAP_AND_DESIGN_SKETCH.md`](docs/CODE_MAP_AND_DESIGN_SKETCH.md): 全体のコードスコアと設計机
- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): 作業手順と文書寿命
- [`docs/HASKELL_NATIVE_CODE_POLICY.md`](docs/HASKELL_NATIVE_CODE_POLICY.md): domainとHaskellの対応、コードの書法と受入条件
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): editorのmain能力、次のslice、安全なwrite effect、writer cutover gate
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): 会計核の不変条件と依存方向
- [`docs/INDEX.toml`](docs/INDEX.toml): 稼働中の正規文書一覧
- [`SECURITY.md`](SECURITY.md): 公開データと秘密情報の境界
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): private正規sourceとwriter authority
