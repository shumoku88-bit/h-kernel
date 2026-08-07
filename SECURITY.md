# セキュリティと世帯データ境界

## 公開リポジトリの境界

このリポジトリはコード、文書、最初から架空にしたexample、fixture、test corpusだけを公開する。正規世帯source、その履歴、backup、生成Reportは含めない。

正規世帯sourceはuser-ownedな別のprivate repositoryに置き、`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`で明示的に選択する。private repositoryをGit submodule、CI fixture、release artifactとして接続しない。

公開してはならないものは次を含む。

- 実際の人名、連絡先、Account番号、外部文書識別子
- 正確な世帯の日付、数量、Transaction、Plan、policy、notebook entry
- credential、token、秘密鍵、認証済みURL
- absolute user path、machine-local設定
- backup、recovery workspace、生成Report、local log
- private repositoryのcommit、Pull Request、Issue、Git objectまたは履歴

synthetic fixtureは正規sourceの値を匿名化・変形して作らず、独立して設計する。

## Writer safety

現在の正規データは`h-kernel`だけで扱い、互換性のない旧applicationをreader、writer、fallbackとして使用しない。repository間のcopy同期とdual writeは禁止する。

h-kernelのwrite operationはvalidation、preview、stale check、atomic publish、backup、post-admission、restoreを迂回しない。未実装operationは暗黙fallbackせず、必要な場合だけ明示的に手編集する。

## ローカル運用

private sourceを読む場合:

```sh
export HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data
./report all
```

または、Git管理外の`ledger-data.local`へdirectory pathを一行で記述する。`.report-artifacts/`を含む出力をcommitしない。

## 問題を報告する

機密値を含む公開Issueを作らない。repository ownerへ非公開で連絡し、値を繰り返さず影響pathを示す。credentialが含まれた場合は直ちにrotateし、既に公開されたGit objectは取得済みの可能性があると扱う。
