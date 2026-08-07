# 正規世帯source

ステータス: アクティブ
Owner: 正規sourceの現在地、h-kernel移行順、安全なwrite条件

## 運用前提

正規データはuser-owned private repositoryのrootに置く。public `h-kernel`にはcode、文書、独立したsynthetic fixtureだけを置く。

現在の正規データ運用は`h-kernel`へ一本化する。`bqn-ledger`は現時点では正規データのreader、writer、fallbackとして使用しない。残っているlegacy sourceはmigration evidenceとして保持するが、その存在を旧applicationへ戻る理由にしない。

将来余裕ができたら、`bqn-ledger`を同じcanonical Household sourceへnative対応させ、reader/writer機能をh-kernelへ追いつかせられる。この将来対応は現在のh-kernel migration gateではなく、h-kernel側へBQN compatibility formatを保存する理由にもならない。

```text
canonical application now  h-kernel
canonical data             separate private repository
bqn-ledger now             not used as reader / writer / fallback
bqn-ledger later           optional native catch-up to the same canonical source
unimplemented h-kernel write
                           explicit manual edit until verified
```

未実装operationを理由に、互換性のないwriterへ戻したりdual writeしたりしない。

## Source inventory

| basename | 現在の意味 | h-kernelの現在地 |
|---|---|---|
| `actual.journal` | Account declaration、Actual fact、completion/reversal evidence | read/write |
| `plan.journal` | native Plan fact | read、CLI write capabilityあり。日常動作を検証中 |
| `accounts.tsv` | retained Account metadata | read。native移行中 |
| `plan.tsv` | legacy Plan source | migration inputのみ |
| `budget_alloc.tsv` | ordered Budget movement | read、CLI write capabilityあり。`budget.journal`へ移行中 |
| `budget.toml` | general Budget policy | read。typed writer未完成 |
| `household.toml` | household policy | read。typed writer未完成 |
| `cycle.tsv`、`config.tsv` | legacy policy/config | migration inputのみ |
| `daily_target_scope.tsv` | Daily Target selection/reservation | native policyへ移行中 |
| `issues.tsv` | household notebook | read、CLI write capabilityあり。日常動作を検証中 |
| legacy report TSV | legacy execution configuration | migration inputのみ |
| `report.toml` | h-kernel Report application config | read |

「CLI write capabilityあり」は正データの日常操作が十分便利で検証済みという意味ではない。commandのpreview、commit、post-admissionをend-to-endで確認するまでは[`../TODO.md`](../TODO.md)のP0未完了として扱う。

## Target

正規rootの目標形は[`HOUSEHOLD_CANONICAL_TARGET.md`](HOUSEHOLD_CANONICAL_TARGET.md)が所有する。

```text
accounts.journal
actual.journal
plan.journal
budget.journal
budget.toml
household.toml
report.toml
issues.tsv
```

legacy sourceは意味をtyped ownerへ移し、semantic parityを確認した後に削除する。旧BQN形式を新しいsourceへ保存することは目標にしない。将来のbqn-ledgerは、新しいcanonical形式へ追従する。

## 将来のcross-engine parity

現在はh-kernelを先に完成させるが、最終的にはh-kernelとbqn-ledgerが同じcanonical sourceを読み、同じdomain operationとReport semanticsを提供する。

共有contractはHaskellの内部型やBQNのarray shapeではなく、次の外部挙動で固定する。

- source syntaxとversion
- identity、ordering、Quantity、Commodity、balance invariant
- operation intent、成功結果、finite failure
- preview、stale rejection、publication後の再admission
- Report query coordinateと会計上の結果
- 独立したsynthetic parity corpus

両applicationがwrite可能になってもdual writeしない。一操作では選択した一つだけを起動し、もう一方は次の操作前にfresh sourceを読み直す。

## Writer law

h-kernelのwrite operationは次を迂回しない。

```text
typed intent
  -> candidate fragment
  -> complete-source admission
  -> preview
  -> explicit confirmation
  -> stale rejection
  -> backup
  -> atomic publication
  -> post-admission
```

- 正データを暗黙に選ばない
- previewなしに変更しない
- preview後にsourceが変わったらwriteしない
- admission failureではsourceへ触れない
- partial writeを残さない
- backup、temporary file、private sourceをpublic Gitへ入れない
- unsupported operationは自動fallbackせず停止する

## Migration order

1. 全commandをsynthetic sourceでend-to-end検証する
2. private sourceを内容非表示でread/admitする
3. write rehearsalは明示的な非canonical copyで行う
4. Account metadataを`accounts.journal`へ移す
5. Budget movementを`budget.journal`へ移す
6. Plan、Issueの日常操作を完成させる
7. retained policy/configを`budget.toml`、`household.toml`、`report.toml`へ移す
8. legacy sourceと現在不要な互換説明を削除する

source format変更、writer実装、UI変更を無関係に一つのsliceへ混ぜない。h-kernelで安全に完了できることを現在の移行条件とする。将来のbqn-ledger対応はこの順序から独立したcatch-upとして扱う。

## Private/public boundary

private repositoryには正確な日付、数量、Account、Transaction、Plan、policy、noteとGit履歴が含まれる。

- private sourceをpublic fixtureへ転用しない
- public CIからprivate repositoryへ接続しない
- diagnosticへprivate値を出さない
- local path、backup、recovery artifactをcommitしない

詳細は[`../SECURITY.md`](../SECURITY.md)に従う。
