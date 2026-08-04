# Household source admission inventory

ステータス: 現在状態のownership inventory  
更新日: 2026-08-04

## 目的

この文書は、Household Report compositionが読むcurrent-format source admissionを列挙し、それぞれが何を読み、どの型へ変換し、どの意味へ依存し、どこが所有しているかを記録する。

これはsource formatの再設計、writer移行、物理file移動の計画ではない。現在のread-only Report結果とsource pathを維持したまま、独立した意味を持つadmissionを一つずつ正しいownerへ移すためのinventoryである。

## 現在のcomposition

```text
actual.journal / plan.journal
stable TOML admissions
stable application config admission
stable daily_target_scope.tsv admission
stable issues.tsv admission
stable budget_alloc.tsv admission
remaining current-format admission
  -> HKernel.Spike.HouseholdReport
  -> HouseholdReportSurface
```

Journal、Plan Journal、application source selection、Budget policy、Household policy、Daily Target scope、Household Issue、Household Budget movementには名前付きadmission ownerがある。

Spike内に残るcurrent-format admissionは`accounts.tsv`だけである。

同じTSV系surfaceを一つのgeneric parserとして扱わず、それぞれの意味に対応するownerへ移している。

## Inventory

| Source | 現在の入口 | typed output | 現在の役割 | 隠れた依存 | ownership |
|---|---|---|---|---|---|
| `accounts.tsv` | `parseAccounts` | `Map Account AccountFact` | retained Account metadataをadmitし、Actual Journal registryと双方向に照合する | `AccountRegistry`、Account role、将来のCommodity evidence、互換metadata | Spike |
| `config.tsv` | `parseApplicationConfig` | `ApplicationConfig` | `ACTUAL_JOURNAL_FILE=actual.journal`という運用上のsource選択を確認する | file path、application startup、未知keyと重複keyの現在挙動 | stable `HKernel.Application.Config` |
| `budget_alloc.tsv` | `parseHouseholdBudgetMovements` | `[HouseholdBudgetMovement]` | retained allocation rowをEntitlementとBackingが共有するmovement factへ変換する | Account、exact Amount、physical line coordinate | stable `HKernel.Household.BudgetMovement.TSV` |
| `issues.tsv` | `parseHouseholdIssues` | `[HouseholdIssue]` | user-authored household matterをtyped Issueへadmitする | `HouseholdIssue` smart constructorだけ。Journal、Account registry、Budget policyへ依存しない | stable `HKernel.Household.Issue.TSV` |

## `accounts.tsv`

### 現在保持するもの

一つのrowから次を読む。

- Account identity
- `role`
- `currency`
- 任意の`kind`
- 任意の`type`
- 任意の`budget`
- 任意の`budget_group`

現在のregistry gateは次を確認する。

- `accounts.tsv`の全Accountが`actual.journal`に宣言されている
- `actual.journal`の全Accountが`accounts.tsv`に存在する
- Account roleが一致する

`currency`はtyped `Commodity`としてadmitされるが、現在のregistry gateではActual Journal declarationとのCommodity一致を照合していない。これは移動時に推測で補わず、Commodity evidenceをどのownerが照合するか合意してから扱う。

### 現在地

Account identityとaccounting typeの正規ownerはJournal側にあり、`accounts.tsv`にはretained household metadataもある。物理rowをそのままstable ownerへ移す前に、正規Account declarationと互換metadataの境界を決める必要がある。

## `config.tsv`

### 現在保持するもの

現在applicationが意味として利用するのは、`ACTUAL_JOURNAL_FILE`が正確に`actual.journal`であることだけである。

`DEFAULT_CURRENCY`を含む他のkeyは入力として受け入れるが、typed application factへ昇格させない。未知keyを拒否せず、重複keyを`Map.fromList`のlast-write-winsへ畳む現在挙動もsource redesignなしで維持する。

### CURRENT owner

`HKernel.Application.Config`がsource textから`ApplicationConfig`へのadmissionを所有する。

```text
config.tsv Text
  -> parseApplicationConfig
  -> ApplicationConfig
```

`ApplicationConfig`のconstructorは公開せず、検証済みのActual Journal選択だけをaccessorから読む。source-local errorはprivate rowを保持せず、physical line coordinateとmessageだけを返す。

Household Report compositionはstable errorを`HouseholdSourceError`へ翻訳するだけであり、KEY=VALUEの形、Map化、source選択規則を再実装しない。この値はHousehold domain factではなく、platform-neutralなapplication source selectionである。

## `budget_alloc.tsv`

### 現在保持するもの

一つのrowから次を読む。

- date
- memo
- from Account
- to Account
- exact quantity
- `currency`

### CURRENT owner

`HKernel.Household.BudgetMovement.TSV`がsource textから`[HouseholdBudgetMovement]`へのadmissionを所有する。

```text
budget_alloc.tsv Text
  -> parseHouseholdBudgetMovements
  -> [HouseholdBudgetMovement]
       -> Entitlement history
       -> Household Backing
```

row admissionは`traverse`でsourceの順序を保つ。Account、Quantity、Commodityの意味検証はそれぞれの既存admissionへ委ね、source-local errorはprivate rowを保持せずline coordinateとmessageだけを返す。

EntitlementとBackingは同じmovement factを別々に解釈する。Household Report compositionはstable errorを`HouseholdSourceError`へ翻訳し、TSV列を再解釈しない。

## `issues.tsv`

### 現在保持するもの

厳密なheaderと8列rowから次を読む。

- stable `IssueId`
- `open`または`resolved` status
- recorded date
- category
- title
- exact Amount
- details

current surfaceではdue dateを推測せず`DueUndetermined`とし、categoryはdetailsの先頭へ`[category]`として保持する。collection内のIssue identityは一意でなければならない。

### CURRENT owner

`HKernel.Household.Issue.TSV`がsource textから`[HouseholdIssue]`へのadmissionを所有する。

```text
issues.tsv Text
  -> parseHouseholdIssues
  -> [HouseholdIssue]
  -> HouseholdReport composition
```

row admissionは`traverse`でsourceの形と順序を保つ。`IssueId`、`Amount`、`HouseholdIssue`の意味検証はそれぞれのsmart constructorへ委ねる。header、status、date、row width、collection identityのfailureは、private rowを保持しない`HouseholdIssueTSVError`としてline coordinateとmessageを返す。

Spikeはこのerrorを既存の`HouseholdSourceError`へ翻訳し、Report compositionへtyped Issueを渡すだけである。Issue domain型、source path、writer authority、rendering、Report結果は変更していない。

## 次の依存順

現時点でSpikeに残るadmissionは`accounts.tsv`だけである。

次のfinite sliceでは、Account declarationとretained household metadataの境界、Commodity evidenceの照合ownerを先に合意し、`accounts.tsv`の物理rowをそのまま安定ownerへ移すと仮定しない。

これは全体ロードマップではない。新しい証拠や設計合意に応じて更新する。

## 維持する境界

- 外部private sourceのpath、内容、writer authorityを変更しない
- bqn-ledgerのwriter authorityを変更しない
- current Report値と表示を変更しない
- source名、行番号、private rowを丸ごと出さないdiagnostic境界を維持する
- admission移動とsource format redesignを同じsliceへ混ぜない
- generic TSV frameworkを先に作らない
