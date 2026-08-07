# 正規世帯source

ステータス: アクティブ
Owner: 正規sourceの現在地、h-kernel移行順、安全なwrite条件

## 運用前提

正規データはuser-owned private repositoryのrootに置く。public `h-kernel`にはcode、文書、独立したsynthetic fixtureだけを置く。

`bqn-ledger`は現在の正規データと互換性がなく、日常reader、writer、fallbackとして使用しない。残っているlegacy sourceはデータとして保持するが、その存在をBQN applicationの継続利用理由にしない。

```text
canonical application  h-kernel
canonical data         separate private repository
bqn-ledger operation   unsupported / not used
unimplemented write    explicit manual edit until h-kernel operation is verified
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

legacy sourceは意味をtyped ownerへ移し、semantic parityを確認した後に削除する。BQN互換形式を新しいsourceへ保存することは目標にしない。

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
8. legacy sourceと互換説明を削除する

source format変更、writer実装、UI変更を無関係に一つのsliceへ混ぜない。ただしBQN writer authorityの承認待ちにはしない。h-kernelで安全に完了できることを移行条件とする。

## Private/public boundary

private repositoryには正確な日付、数量、Account、Transaction、Plan、policy、noteとGit履歴が含まれる。

- private sourceをpublic fixtureへ転用しない
- public CIからprivate repositoryへ接続しない
- diagnosticへprivate値を出さない
- local path、backup、recovery artifactをcommitしない

詳細は[`../SECURITY.md`](../SECURITY.md)に従う。
