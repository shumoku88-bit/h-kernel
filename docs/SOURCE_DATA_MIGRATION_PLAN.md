# 正規世帯sourceの所有権と移行

ステータス: アクティブ  
Owner: household source topology、writer authority、native source migration

## 1. 現在の配置

正規世帯sourceは`h-kernel`のGit履歴には置かず、user-ownedな別のprivate repositoryに置く。

```text
canonical location  separate private data repository
current writer      bqn-ledger editor
current readers     bqn-ledger and h-kernel
future writer       h-kernel editor after explicit cutover
public h-kernel     code, docs, synthetic evidence only
```

`h-kernel`は`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`からdirectoryを明示的に受け取る。private repositoryの名前やpathをcode、fixture、CIへ固定しない。

## 2. Source ownership

現在のprivate source setには次の意味がある。

| basename | owner class | current writer/readers |
|---|---|---|
| `actual.journal` | Account declaration、Actual fact、completion evidence | bqn-ledger / both engines |
| `plan.journal` | native Plan fact | bqn-ledger / h-kernel |
| `accounts.tsv` | retained Account metadata | bqn-ledger / both engines |
| `plan.tsv` | retained Plan compatibility source | bqn-ledger |
| `budget_alloc.tsv` | ordered Budget movement fact | bqn-ledger / both engines |
| `budget.toml` | general Budget policy | user / h-kernel |
| `household.toml` | household-specific policy | user / h-kernel |
| `cycle.tsv`、`config.tsv` | retained compatibility policy/config | bqn-ledger / both engines |
| `daily_target_scope.tsv` | retained Daily Target selection and reservation declaration | bqn-ledger / both engines |
| `issues.tsv` | household notebook source | bqn-ledger / both engines |
| report manifest files | retained bqn-ledger execution configuration | bqn-ledger |

同じphysical directoryにあることは、fact、policy、projection、execution configが同じdomain ownerを持つことを意味しない。

## 3. Private/public boundary

private repositoryには正確な日付、数量、Account、Transaction、Plan、policy、noteが含まれる。その現在値だけでなく、commit、branch、Pull Request、Issue、backup、recovery artifactも公開しない。

public repositoryのexampleとtest corpusは独立したsynthetic dataだけを使う。private sourceを匿名化、丸め、日付shiftしてfixtureへ転用しない。CIはprivate repositoryをcheckoutせず、secretやtokenで接続しない。

詳細は[`../SECURITY.md`](../SECURITY.md)が所有する。

## 4. 一人のwriter

- `bqn-ledger`の`LEDGER_DATA_DIR`はprivate canonical directoryを指す。
- `h-kernel`は同じdirectoryをread-onlyでadmitする。
- public checkout内に同期copyを作らない。
- source rowをrepository間でcopyまたはmergeするscriptを置かない。
- validation failure時は通常writeを止め、canonical directoryそのものを修復する。
- backupはcanonical Git treeとpublic Git履歴の外に置く。

private repositoryへの物理分離はwriter authorityの移動ではない。明示的なcutoverまでは`bqn-ledger`がwriterである。

## 5. h-kernel-native target

目標source shapeは小さく保つ。

```text
accounts.journal
actual.journal
plans.journal
budget.journal
household.toml
issues.tsv
```

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transactionと明示的completion relation
- `plans.journal`: 将来commitment、identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered Budget decisionとprovenance
- `household.toml`: stable household policy
- `issues.tsv`: 会計factを暗黙生成しないnotebook source

このtargetは方向であり、current compatibility fileを証拠なしに削除する許可ではない。

## 6. Source migration law

- current fieldをfact、policy、projection、execution config、noteへ分類する。
- unknown key、column、metadata、status、Commodity、relationを黙って捨てない。
- Account名や残高からAccountType、Budget membership、liquidity、completionを推測しない。
- conversionはsource commitとconverter versionに対してdeterministicにする。
- Account identity、Actual、Plan、Budget、policy、ordering、provenanceのsemantic parityを観察する。
- source format migrationとwriter cutoverを同じsliceへ混ぜない。

## 7. h-kernel editor cutover gate

writer authorityは、少なくとも次を満たす明示PRでのみ移す。

1. 必要なAccount、Actual、Plan、Budget、policy、notebook operationのparity
2. mutation前previewとstrict complete-source admission
3. stale source rejection
4. atomic publishとpartial write不在
5. ignored backup、failure test、restore
6. duplicate identity、exact Quantity、Commodity別balance、provenanceの維持
7. synthetic sourceとprivate source copyを使った運用rehearsal
8. bqn-ledgerとのsemantic comparison
9. dual writeを防ぐ運用変更
10. 作者による明示承認

cutover完了までは`bqn-ledger`が唯一のwriterであり、`h-kernel` editorの試験はsynthetic sourceまたは明示的な非正規copyを対象にする。

## 8. 検証

public codeの標準検証:

```sh
cabal build all
cabal test all
cabal run repository-audit
sh ./report-verify --fixture
sh ./report-verify --corpus
```

private canonical sourceへ影響する変更では、内容を出力せず明示directoryで追加検証する。

```sh
HKERNEL_LEDGER_DATA_DIR=/absolute/path/to/private-ledger-data ./report all >/dev/null
```
