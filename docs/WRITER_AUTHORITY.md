# Canonical source writer authority

ステータス: 承認済みcurrent contract  
Owner: source別writer authority、single-writer law、writer cutover gate  
更新日: 2026-08-12

## 1. この文書の役割

この文書は、canonical Household sourceの**現在のwriter authority law**だけを所有する。

現在のreader topologyと8本のcanonical sourceは[`HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md)が所有する。source formatとengine-neutralなcanonical contractは[`HOUSEHOLD_CANONICAL_TARGET.md`](HOUSEHOLD_CANONICAL_TARGET.md)が所有する。過去のmigration手順、途中のsource配置、完了済みroadmapはGit履歴とmerged PRが所有する。

同じphysical directoryにあること、readerがsourceをadmitできること、Editorにwrite capabilityがあることはwriter authorityを意味しない。

## 2. Current authority

### `actual.journal`

`actual.journal`のcanonical writer authorityは`h-kernel` editorにある。

```text
actual.journal
  canonical writer  h-kernel editor
  readers           h-kernel and bqn-ledger
```

このauthorityは2026-08-06のActual-only cutoverで明示的に移された。activation、daily operation、stop、rollbackの詳細は[`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md)が所有する。

`bqn-ledger`をreaderまたはReport engineとして使うことはできるが、canonical `actual.journal`を変更するBQN operationへ切り替えない。

### Other canonical sources

このrepositoryには、`accounts.journal`、`plan.journal`、`budget.journal`、`budget.toml`、`household.toml`、`report.toml`、`issues.tsv`のwriter authorityを新しいimplementationへ移したと宣言するapproved cutover contractはない。

したがって次を守る。

- h-kernelにAccount / Plan / Budget / Issueのwrite capabilityが存在しても、それだけからcanonical authority移動を推測しない。
- Actual-only cutoverから他sourceのauthority移動を推測しない。
- current operational writerを別implementationへ切り替える場合は、sourceごとのcutover evidenceと作者の明示承認を先に持つ。
- capability追加、TUI/CLI追加、reader migration、source format migrationをwriter cutoverと同一視しない。

この文書は、証拠のないsourceについて特定engineをcanonical writerだと新しく宣言しない。

## 3. Single-writer law

canonical sourceごとに、運用中のwriter authorityは一つにする。

```text
one canonical source
  -> one approved operational writer
  -> zero alternating / dual writers
```

- 同じsourceへh-kernelとbqn-ledgerを交互にwriteしない。
- safe publication capabilityが複数engineにあっても、authorityは自動的に共有されない。
- reader compatibilityはwriter authorityとは別に確認する。
- source format migrationとwriter cutoverは別chapterとして扱う。
- writer authority rollbackをsource rollbackやreader fallbackと暗黙に同時実行しない。

## 4. Writer cutover gate

source別writer authorityは、少なくとも次を満たす明示changeでのみ移す。

1. 対象sourceに必要なoperation parity
2. mutation前previewとstrict complete-source admission
3. stale source rejection
4. atomic publicationとpartial write不在
5. ignored backup、failure test、checked restore
6. identity、exact Quantity、Commodity、provenanceなど対象sourceの不変条件維持
7. synthetic sourceと、秘密を出力しないprivate rehearsal
8. 旧writerとのsemantic comparison
9. dual / alternating writeを防ぐ運用変更
10. 作者によるwriter authority移動の明示承認

write pathがこのgateを技術的に満たしていても、10の承認なしにauthorityは移らない。

## 5. Stop and recovery

次の場合はcanonical writeを通常継続しない。

- source admission failure
- stale rejection
- publication後のadmission failure
- checked restore失敗
- filesystem failure
- 同一sourceへ複数writerが向いている疑い
- writer authorityが不明な状態

safe writerの具体的なpublication lawは[`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md)と実装ownerが所有する。writer authorityの不明確さをgeneric lock、repository abstraction、dual writeで隠さない。

## 6. Authority変更時の文書更新

writer cutoverを行うchangeでは、この文書のcurrent authorityを同じchangeで更新する。source固有のactivation / stop / rollbackに追加の意味がある場合だけ、`ACTUAL_WRITER_CUTOVER_001.md`のようなsource-specific contractを置く。

完了済みmigrationの作業ログや旧source一覧をcurrent contractへ保存しない。過去の状態はGit履歴とmerged PRから確認する。

## 7. Related owners

- [`HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md`](HOUSEHOLD_SOURCE_ADMISSION_INVENTORY.md): current canonical reader topology
- [`HOUSEHOLD_CANONICAL_TARGET.md`](HOUSEHOLD_CANONICAL_TARGET.md): engine-neutral canonical source contract
- [`ACTUAL_WRITER_CUTOVER_001.md`](ACTUAL_WRITER_CUTOVER_001.md): `actual.journal` authorityの具体的なactivation / stop / rollback
- [`EDITOR_DEVELOPMENT_PLAN.md`](EDITOR_DEVELOPMENT_PLAN.md): Editor capabilityとsafe writer law
- [`REPOSITORY_POLICY.md`](REPOSITORY_POLICY.md): document lifecycleとauthority changeの作業単位
- [`../SECURITY.md`](../SECURITY.md): private/public boundary
