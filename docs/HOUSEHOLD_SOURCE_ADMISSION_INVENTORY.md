# Household source admission inventory

ステータス: 現在状態のownership inventory  
更新日: 2026-08-05

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
stable accounts.tsv compatibility admission
  -> HKernel.Spike.HouseholdReport
  -> HouseholdReportSurface
```

Journal、Plan Journal、application source selection、Budget policy、Household policy、Daily Target scope、Household Issue、Household Budget movement、retained Account profileには名前付きadmission ownerがある。

`HKernel.Household.AccountProfile.TSV`が`accounts.tsv`のsyntax、semantic classification、Actual Journal registry parityを所有する。Household Report compositionはstable adapterを呼び、`AccountProfileTSVError`を既存`HouseholdSourceError`へ翻訳するだけである。

Spike内にはcurrent-format source syntax parserが残っていない。同じTSV系surfaceを一つのgeneric parserとして扱わず、それぞれの意味に対応するownerへ移している。

## Inventory

| Source | 現在の入口 | typed output | 現在の役割 | 隠れた依存 | ownership |
|---|---|---|---|---|---|
| `accounts.tsv` | `admitRetainedAccountProfiles` | `Map Account RetainedAccountProfile` | Account declaration、Budget policy evidence、Household policy evidence、unknown metadataを分離し、Actual Journal registryと双方向に照合する | `AccountRegistry`、AccountType、default Commodity、retained compatibility metadata | stable `HKernel.Household.AccountProfile.TSV` |
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
- 任意の`envelope_role`
- 任意の`fixed`
- 任意の`spend_class`
- 未分類の任意metadata

stable admissionは`role`と`currency`を`AccountDeclaration`へ変換し、それ以外のmetadataを`HKernel.Household.AccountProfile`へ渡す。unknown keyとAccountTypeに適用できない既知keyは削除せず、unclassified metadataとして保持する。

stable registry gateは次を確認する。

- `accounts.tsv`の全Accountが`actual.journal`に宣言されている
- `actual.journal`の全Accountが`accounts.tsv`に存在する
- Account roleが一致する
- Actual Journalがper-Account default Commodityを明示している場合、その値がretained evidenceと一致する

AccountTypeと明示されたdefault Commodityは別の座標として診断する。Actual側のper-Account defaultが省略されている場合は「別のCommodity」ではなく「このsourceでは未宣言」と扱い、`accounts.tsv`のretained evidenceを失わない。

### CURRENT owner

```text
accounts.tsv Text
  -> HKernel.Household.AccountProfile.TSV
  -> AccountDeclaration + retained metadata
  -> HKernel.Household.AccountProfile
  -> Map Account RetainedAccountProfile
  -> Actual Journal AccountRegistry compatibility parity
  -> Household Report composition
```

source-local errorはprivate rowを保持せず、source名、physical line、messageだけを返す。duplicate Account、duplicate metadata、malformed field、unsupported role、invalid Commodity、semantic classification failureをadmission境界で拒否する。

Household Report compositionはstable errorを`HouseholdSourceError`へ翻訳し、TSV field、role、Commodity、registry reconciliationを再実装しない。Spike-local `AccountFact`、`parseAccounts`、`parseAccountMetadata`、`parseRole`、旧registry gateは削除済みである。

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

current-format source admissionのownership移動は完了した。Household Report compositionは全sourceを名前付きstable admissionから受け取り、Spikeはtyped compositionとerror translationだけを行う。

次のAccount migration sliceは、現在のreaderを変えずにAccount declarationのdeterministic shadow conversionを置く。

```text
retained accounts.tsv
  -> stable Account profile admission
  -> AccountDeclaration projection
  -> synthetic accounts.journal shadow
  -> parseAccountJournal
  -> exact declaration parity
```

compatibility readerではActualの省略されたper-Account Commodityを矛盾とみなさない。一方、生成する`accounts.journal`にはretained Commodity evidenceを明示し、その生成物を再admitした`AccountDeclaration`とprojectionをexact equalityで照合する。

Account declaration shadow conversionと、retained Budget/Household policy evidenceのTOML移行を同じsliceへ混ぜない。writer authority、private source format、current Report値は別の明示gateまで変更しない。

これは全体ロードマップではない。新しい証拠や設計合意に応じて更新する。

## 維持する境界

- 外部private sourceのpath、内容、writer authorityを変更しない
- bqn-ledgerのwriter authorityを変更しない
- current Report値と表示を変更しない
- source名、行番号、private rowを丸ごと出さないdiagnostic境界を維持する
- admission移動とsource format redesignを同じsliceへ混ぜない
- generic TSV frameworkを先に作らない
