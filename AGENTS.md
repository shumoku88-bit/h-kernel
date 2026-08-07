# h-kernel 作業入口

このファイルは、h-kernelで作業するpitの共通入口である。

## 作業前

1. [`TODO.md`](TODO.md)を読み、最上位の未完了項目から一つの有限sliceを選ぶ。
2. 最新`origin/main`、open PR、関連branch、対象code/testを確認する。
3. [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)と対象domainのcontractだけを読む。
4. Editorまたは正データへ触れる場合は[`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md)、[`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md)、[`SECURITY.md`](SECURITY.md)を読む。

`bqn-ledger`は現在の正規データに対するreader、writer、fallbackとして使わない。未対応operationはh-kernelで完成させ、互換性のない旧applicationへ戻さない。

## 作業単位

- 一度に一つの利用者目的を扱う。
- correctness、source format、UI、writer effect、文書整理を無関係に混ぜない。
- 既存のdomain owner、型、testを先に再利用する。
- Account名や残高から会計上の意味を推測しない。
- 将来のadapterだけを理由に抽象を追加しない。
- 変更で不要になったwrapper、互換説明、古い文書を同じsliceで削除する。
- 新しい計画文書を作らず、優先順位は`TODO.md`へ、現在の契約は既存ownerへ反映する。

Haskell codeを変更する前に、短く次を確認する。

```text
Domain phrase:
Domain structure:
Haskell phrase:
Correspondence:
Rejected phrases:
Evidence:
```

詳細な書法は[`docs/HASKELL_NATIVE_CODE_POLICY.md`](docs/HASKELL_NATIVE_CODE_POLICY.md)に従う。

## 標準検証

```sh
cabal build all
cabal test all
cabal run exe:repository-audit
```

Reportへ影響する場合:

```sh
./report-build
./report-verify --fixture
./report-verify --corpus
```

private sourceへ影響する場合は内容を出力せずread/admissionを確認する。write rehearsalは正データではなく明示的な非canonical copyだけで行う。

```sh
HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data ./report all >/dev/null
```

## 文書owner

- [`TODO.md`](TODO.md): 優先順位と完了条件
- [`README.md`](README.md): 現在の利用方法
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): componentと依存方向
- [`docs/EDITOR_DEVELOPMENT_PLAN.md`](docs/EDITOR_DEVELOPMENT_PLAN.md): Editor境界
- [`docs/SOURCE_DATA_MIGRATION_PLAN.md`](docs/SOURCE_DATA_MIGRATION_PLAN.md): 正規source
- [`docs/REPOSITORY_POLICY.md`](docs/REPOSITORY_POLICY.md): 作業と文書寿命
- [`SECURITY.md`](SECURITY.md): private/public境界
