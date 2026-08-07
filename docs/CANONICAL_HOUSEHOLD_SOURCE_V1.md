# Canonical Household Source v1

ステータス: active migration target  
Owner: household root shape and source/config ownership

## 目的

private `household-ledger-data` rootを、TUIやReportが個別legacy source名を指揮しなくてよい小さいHousehold rootへ収束させる。

これはsource数を最小化するための最終固定ではない。まず意味のownerを明示し、運用後に不要な境界をさらに統合できる形を作る。

## Target shape

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

### Declaration / fact sources

- `accounts.journal`: Account identity、AccountType、optional default Commodity
- `actual.journal`: Actual Transaction、durable identity、completion relation
- `plan.journal`: Plan identity、schedule、recurrence、lifecycle relation
- `budget.journal`: ordered Budget movement factとprovenance

### Policy / application configuration

- `budget.toml`: general Budget policy
- `household.toml`: household-specific policy
- `report.toml`: Report query defaultsとpresentation policy

### Notebook

- `issues.tsv`: 会計factやBudget policyを暗黙生成しないhousehold notebook

## Household root law

Application adapterはHousehold rootを一つ受け取り、canonical basenameをowner側で解決する。

```text
HouseholdRoot
  -> typed source admission
  -> Household values
  -> CLI / TUI / Report
```

TUIが`accounts.tsv`、`budget_alloc.tsv`、legacy Report manifestなどの互換sourceをcommand hubとして直接編成する構造をtargetに持ち込まない。

## Report configuration

`report.toml`はcanonical household factではないが、このHousehold rootに属するReport application configurationとして配置できる。

`tools/hk --base DIR report ...`は、explicit `HKERNEL_REPORT_CONFIG`が無い場合に限り`DIR/report.toml`を採用する。explicit environment overrideは引き続きauthorityを持つ。

legacy `report_manifests.tsv`、`report_all_human.tsv`、`report_all_compact.tsv`はtyped Report entrypointのparityを確認してからretireする。source filename、Account classification、Envelope membershipを`report.toml`へ複製しない。

## Migration state

private migration branchでは次をnative targetとして先行作成する。

- `accounts.journal`
- `report.toml`

`accounts.journal`は既存`HKernel.Household.AccountProfile.TSV`のdeterministic shadow rendererと同じsyntax・orderingを使用する。`accounts.tsv`は残るmetadataのowner移行とreader cutoverが終わるまでretained evidenceとして削除しない。

`budget.journal`はnative admissionとTSV conversion parityをh-kernel側で確立する前にplaceholderを作らない。

## Writer authority

source format migrationからwriter authority移動を推測しない。

- `actual.journal`のcurrent canonical writerはh-kernel editor
- 他sourceはそれぞれ明示的cutoverまでcurrent authorityを維持
- dual writeとalternating writerは禁止

## Legacy retirement gate

legacy sourceを削除する前に、そのsourceが所有していた全coordinateを次へ分類する。

1. canonical declaration / fact
2. Budget policy
3. Household policy
4. Report application config
5. derived projection
6. notebook / note
7. obsolete compatibility coordinate

unknown metadata、identity、ordering、Commodity、relationを黙って捨てない。

## 将来の引き算

v1の8 source/configは永久固定ではない。運用後、同じowner・同じ変更理由・同じwriter authorityを持つ境界だけを改めて統合できる。

先に意味を分け、その後に根拠を持って減らす。
