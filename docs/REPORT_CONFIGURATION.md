# レポート構成

ステータス: 実装契約  
範囲: `ReportBook`が公開するJournal Reportの期間queryとpresentation

## 目的

`report.toml`は、レポートごとの**query policy**とpresentationを宣言する。実際の取引日、現在サイクルの開始日、Account分類、Envelope membershipのようなHousehold事実・policy座標は所有しない。

設定はレポートengineへ到達する前にtyped valueへ変換される。

```text
report.toml
  -> TOML syntax decoding
  -> symbolic ReportPlan
  + one process-local observation day
  + validated Journal
  + current Household Period when the query requires it
  -> ResolvedReportPlan
  -> typed report projections

report.toml presentation values
  -> validated PresentationConfig
  -> shared renderers
```

通常の期間queryはJournalだけで解決できる。`current-cycle-to-date`だけは、Householdがすでに解決したcurrent `Period`を追加contextとして必要とする。Report層がincome anchorやcycle policyを再実装してはならない。

## 設定の探索

Report configurationの探索はHaskell application entrypointが所有する。日常TUI launcher `tools/hk` はReportをroutingせず、standalone Reportは`report` entrypointへ直接到達する。

通常は次の順で設定を探す。

1. `HKERNEL_REPORT_CONFIG`で明示したpath
2. `HKERNEL_LEDGER_DATA_DIR`または`ledger-data.local`でHousehold rootが設定され、そのrootにあるcanonical `report.toml`
3. current working directoryの`report.toml`
4. 設定なしの場合は既存のReport既定値

明示したpathが読めない、または設定がinvalidな場合はsilent fallbackしない。

canonical Household rootから`all`を生成する場合、`loadCanonicalHousehold`がcanonical sourceを一度admitし、その`HouseholdState`からActual Journal、Report configuration、Household report surfaceを得る。Report appがcanonical `report.toml`を先読みして別のfailure orderを作らない。

`HKERNEL_REPORT_CONFIG`がcanonical rootとは別pathを指定した場合、そのfileはReport query/presentation overrideとしてadmitする。ただしcanonical Household admission自体は迂回しない。

## 期間query

### `latest`

`latest`はprocess開始時に一度得たローカル暦日を意味する。Journal内の最大transaction日ではない。

```toml
[reports.trial-balance]
as-of = "latest"
```

### `beginning`

`beginning`はexplicit rangeの開始境界だけで使える。解決済み終了日以前の最古transaction日へ解決する。該当transactionがなければ終了日そのものへ解決し、有効な空rangeを作る。

```toml
[reports.monthly-accounts]
from = "beginning"
through = "latest"
```

### 明示日付

明示日付は`YYYY-MM-DD`で書く。rangeはinclusiveで、開始が終了より後ならreport名付きのresolution errorになる。

```toml
[reports.profit-and-loss]
from = "2026-06-15"
through = "2026-08-16"
```

明示日付は過去期間の再現、snapshot、fixture/golden、engine比較、特別な分析で引き続き第一級のqueryである。

### `current-cycle-to-date`

日常のP&LとDaily Flowは、具体的なサイクル開始日を書き換える代わりに次を指定できる。

```toml
[reports.profit-and-loss]
range = "current-cycle-to-date"

[reports.daily-flow]
range = "current-cycle-to-date"
max-date-columns = 10
```

意味は厳密に次である。

```text
start = already-resolved current Household Period start
end   = the same process-local observation day
```

current `Period`は`household.toml`のcycle policy、Actual income anchor、future Plan income anchor、observation dayからHousehold ownerが解決する。`report.toml`はcycle開始日やincome Accountを保持しない。

`range = "current-cycle-to-date"`と`from` / `through`は排他的である。混在、`from`だけ、`through`だけはfail closedする。

現在このsymbolic rangeを受理するのは次だけ。

- Profit & Loss
- Daily Flow

Monthly Accountsへはまだ拡張しない。`current-cycle-complete`、previous-cycle系queryも現在のcontractには存在しない。

## Household contextとstandalone Report

Household-relative queryの解決は次のように分かれる。

```text
canonical Household all
  -> Household report surface
  -> current Period
  -> resolve ReportPlan

TUI
  -> the same admitted Household surface
  -> current Period
  -> resolve ReportPlan

standalone report + configured Household root
  -> load Household cycle context only when ReportPlan needs it
  -> resolve ReportPlan

pure Journal + current-cycle-to-date
  -> error: current Household cycle context is required
```

pure JournalからAccount名や日付類似でcycleを推測しない。月初などへのfallbackもしない。

渡されたcurrent `Period`がobservation dayを含まない場合もfail closedする。これによりstaleなcycle contextを通常のDateRangeとして扱わない。

## CLI override

単一Report commandへ明示的なCLI日付・範囲を渡した場合、その座標が設定期間より優先する。presentation configは維持される。

```text
explicit CLI date/range
  -> use explicit report request
  -> do not require symbolic range resolution
  -> keep PresentationConfig
```

そのため、`current-cycle-to-date`を含むconfigがあっても、明示的な過去期間Reportを再現するためにcycle contextを要求しない。

`check`とEnvelope固有commandはReport configurationを読まない。

## ReportBookとstandaloneの同等性

同じ解決済みreport requestと同じ`PresentationConfig`なら、`all`内のpayloadとstandalone Report payloadは同じrenderer意味を使う。ReportBookだけ別のnumber formatting、color policy、date-column policyを持たない。

```text
all        -> resolved report -> shared renderer + PresentationConfig
standalone -> resolved report -> shared renderer + PresentationConfig
```

期間policyとpresentation policyは独立している。

## 例

日常利用の例:

```toml
[presentation.hierarchy]
heading-color = "cyan"
section-color = "yellow"

[presentation.amounts]
negative-style = "parentheses"
positive-color = "green"
negative-color = "red"

[reports.trial-balance]
as-of = "latest"

[reports.balance-sheet]
as-of = "latest"

[reports.profit-and-loss]
range = "current-cycle-to-date"

[reports.daily-flow]
range = "current-cycle-to-date"
max-date-columns = 10

[reports.monthly-accounts]
from = "beginning"
through = "latest"

[reports.recent-transactions]
through = "latest"
count = 5
```

`report.toml.example`もこの日常利用形を示す。

過去を固定期間で再現する場合はsymbolic queryを使わず、対象Reportへexplicit `from` / `through`を書く。

## Presentation semantics

`presentation.hierarchy`と`presentation.amounts`は独立してoptionalで、tableがない場合は既定値を使う。

`presentation.hierarchy.heading-color`と`section-color`はreport hierarchyだけを変更する。既定値は`cyan`と`yellow`。

`presentation.amounts.negative-style`は次を受け付ける。

- `parentheses`
- `minus`

既定値は`parentheses`。これは表示だけを変え、signed `Quantity`、`Amount`、`Balance`を変更しない。

color座標は次を受け付ける。

- `red`
- `bright-red`
- `green`
- `yellow`
- `blue`
- `magenta`
- `cyan`
- `white`

status color、bold、dimはamount paletteとは別のpresentation意味を持つ。

`reports.daily-flow.max-date-columns`もpresentation coordinateであり、`all`とstandalone Daily Flowで共有する。既定値は`14`。

## Daily Flow calendar blocks

configured rangeまたはexplicit rangeでは、activityがない日もinclusive range内の暦日として表示する。

`max-date-columns`は一つのtable blockの日付列数を制限する。例えば31日rangeと`max-date-columns = 10`は10日、10日、10日、1日の4 blockになる。

複数blockでは各行に`Block total`と`Period total`を表示する。`Block total`はそのblockだけ、`Period total`は解決済みrange全体を表す。単一blockでは重複する`Block total`を省略する。

設定なしのlegacy default Daily Flowだけは、明示startのないthrough-windowを維持する。
