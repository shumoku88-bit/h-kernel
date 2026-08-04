# 予算計画のコミットメントの観察 - 支援前に現金を確保


## 1. ステータス


この文書は、`docs/BUDGET_BACKING_OBSERVATION.md` に対する補足です。


これは、銀行残高の一部がすでに未払いの予定支払に充当されている場合に、その残高を完全に利用可能な裏付けとして扱うことができない理由を記録します。


これは観察であり、プラン パーサー、プラン計算、バッキング計算、またはファイル形式の決定ではありません。


観察された h-kernel のメイン コミット:


```text
fc908345f936d2f79fb42c0ed2b3225d7bd771e0
```


観察された bqn-ledger のメインコミット:


```text
606d1deaa3ba2f0ea06d31bf7d5d846c7c585e0c
```


## 2. 有限の質問


> h-kernel は、未払いの予定支払いのために資金を確保しつつ、支払いが実際の Journal トランザクションになった後の二重減算を避け、利用可能なEnvelopeにその資金が再び割り当てられないようにするにはどうすればよいか?


有限のスコープは次のとおりです。


- 1 つ選択された `BudgetCycle`、

- 明示的な `observedThrough` 日、

- 正確な支払い計画、

- 正確な実際のジャーナル証拠、

- `BudgetPolicy` の費用とバッキング プール トポロジ、

- そして、利用可能な裏付けと利用可能な封筒のお金に対するオープンな支払いコミットメントの影響。


この観察では、定期的な計画の生成、カレンダー UI、通知、支払いの開始、銀行の同期、評価、または一般的な予測は実装されていません。


## 3. 観察された発生源


### 3.1 h-カーネル


```text
docs/BUDGET_BACKING_OBSERVATION.md
docs/BUDGET_MODEL_OBSERVATION.md
src/HKernel/Budget/Policy.hs
src/HKernel/Budget/Entitlement.hs
src/HKernel/Budget/Consumption.hs
src/HKernel/Budget/Remaining.hs
src/HKernel/Engine/Facts.hs
```


### 3.2 観察されたコミット時の bqn-ledger


```text
docs/PLAN_ID_LIFECYCLE.md
docs/PLAN_COMPLETION_JOIN.md
src/accounting/plan_completion_join.bqn
src/accounting/envelope_backing.bqn
src/sections/planned_payments.bqn
tests/test_accounting_plan_completion_join.bqn
tests/test_accounting_envelope_backing.bqn
fixtures/envelope-plan/README.md
```


bqn-ledger は、動作している隣接システムとして観察されます。そのファイルの形状と式は、h-kernel 用に自動的に契約されるわけではありません。


## 4. 4 人の異なる情報所有者


現在の予算モデルには、崩れてはいけない 4 つの意味が必要です。


```text
Journal        what actually happened
BudgetHistory  how much spending permission was granted
BudgetPolicy   which accounts, envelopes, and pools are related
Plan           which future payment has already reserved money
```


支払いが発生していないため、プランは仕訳帳トランザクションではありません。


プランは資格を付与または取り消すものではないため、`BudgetChange` ではありません。既存のお金や支出許可の一部は自由に再利用できなくなるという。


```text
BudgetChange  "Food may use 50,000 JPY"
Plan          "6,000 JPY of that money is committed to an unpaid order"
Journal       "the 6,000 JPY payment occurred"
```


## 5. bqn-ledger がすでに証明していること


### 5.1 耐久プランのアイデンティティ


bqn-ledger は、正規の空ではない `plan_id` を使用して、1 つの計画トランザクションを実際のトランザクション証拠に接続します。


厳密な完了結合では、メモ、日付、金額、または 5 つのフィールドのフォールバックから ID を推測しません。


これにより、有用な一般規則が確立されます。


```text
payment completion is an identity relation, not a resemblance test
```


### 5.2 明示的な関係状態


選択したプランについて、正規結合は次のいずれかの状態を公開します。


```text
open       no selected Actual has the plan_id
completed  exactly one valid Actual has the plan_id
duplicate  several identical Actual completions exist
ambiguous  several conflicting Actual completions exist
```


重複した曖昧な証拠が黙って支払われたものとして扱われることはありません。


これは、修復が必要な証拠を保持するため、ブール値 `isPaid` フィールドよりも強力です。


### 5.3 計画と実績は依然として別個の情報源である


結合は、承認された計画ファクトと実際のファクトを個別に消費します。支払いが発生したときに Plan 行を書き換えたり削除したりすることはありません。


完成はソース間の関係から導き出されます。


これにより、追加のみの履歴がサポートされ、完了した計画が履歴証拠として失われるのを防ぎます。


### 5.4 オープンプランの予約はすでに存在します


観測された`src/accounting/envelope_backing.bqn`:


1. 観察日を選択します。

2. その日を通して実際の残高と支出活動を観察します。

3. `plan_id` により、選択された計画行を選択された実際の行に結合します。

4. 開いているプランの宛先経費勘定を封筒カテゴリにマッピングします。

5. 封筒ごとに `open_plan_reserve` を合計します。

6. 元帳残存額からオープン計画の準備金を差し引いたものとして `post_plan_headroom` を導出します。


観察されたテスト スイートでは、オープンな計画準備金、実際の消費量、払い戻し、超過支出、および資金残高が別個の結果フィールドのままであることが証明されています。


これは、未払いのプランを実際の消費であるかのように装うことなく、予約として表すことができるという直接的な証拠です。


## 6. h-kernel に何を入れるべきか


次のセマンティクスは、h-kernel の適切な候補です。


1. 支払いプランには永続的なアイデンティティがあります。

2. 完成は実際の証拠と一致することで得られます。

3. オープン、完了、重複、および曖昧は別個の状態です。

4. 有効な支払い約定の準備金のみをオープンしてください。

5. 正確な量と商品の同一性は保持されます。

6. 計画と実際の来歴は別々に表示されたままになります。

7. 完了すると、プランの破壊的な削除ではなく、関係によって予約が削除されます。


`plan.tsv` という名前は将来のアダプター名として考えられますが、ストレージ形式をコピーする前にドメイン契約を導入する必要があります。


## 7. やみくもにコピーしてはいけないもの


### 7.1 h-kernel には明示的なバッキング プールがあります


観察された bqn-ledger バッキング所有者は、選択された 1 つの資金資産インデックスのセットを受け取ります。


h-kernel にはすでに強力なトポロジがあります。


```text
Asset account -> BackingPoolId
EnvelopeId    -> BackingPoolId
```


したがって、h-kernel コミットメントでは、1 つの未分化な資金調達範囲ではなく、プール座標を公開する必要があります。


### 7.2 計画日がコミットメント状態と同じではない


bqn-ledger の計画ライフサイクルでは、実際の完了証拠が欠落しているため、`open` が定義されています。その [計画された支払い] セクションでは、開いている行に期限超過、期日、または将来のラベルを付けることができます。


観察されたエンベロープバッキングの所有者は、観察日からサイクル終了までの計画日付を選択します。これにより、期限を過ぎてもまだオープンなプランは予備の選択から除外されます。


ユーザーの銀行予約要件により、期限を過ぎた予定引き出しには、完了するかキャンセルされるまで、引き続き予約された現金が必要になる場合があります。


したがって、h-kernel はアクティブ コミットメントを単に次のように定義してはなりません。


```text
plannedDate >= observedThrough
```


ライフサイクル状態と時間ラベルは別個の座標です。


### 7.3 すべての予測が約束されるわけではない


将来の購入の可能性と、すでに予定されている銀行引き落としでは、影響力が異なります。


最初の h-kernel Plan スライスは次のいずれかを行う必要があります。


- 約束された出金のみを認める、または

- 明示的なコミットメント分類を行う。


すべての投機的予測を黙って予備の現金として扱うと、予算が不必要に利用できなくなります。


### 7.4 資金源は推測できない


プランでは、明示的な `fromAccount` および `toAccount` の方向を保持できます。


`fromAccount` は、バッキング プールがプールに割り当てられているアセットである場合に、バッキング プールを識別できます。 `toAccount` は、封筒に割り当てられた経費である場合、封筒を識別できます。


どちらかの関係が存在しない場合、h-kernel はアカウント名やトランザクションの形式から推測するのではなく、その事実を保持する必要があります。


## 8. 1 つのオープンな計画、2 つの独立した予測


封筒関連の予定された支払いは、2 つの異なる自由に影響を与えます。


```text
open committed Plan
  -> pool commitment
  -> envelope commitment
```


これらは、1 つの計画アイデンティティからの 2 つの予測です。これらは重複したソース レコードではありません。


### 8.1 プールのコミットメント


オープンな送信プランがバッキング プールに属するアセット アカウントから引き出される場合:


```text
PoolCommitment coordinate
= observedThrough x BackingPoolId x Commodity
```


その金額により、新規または既存のエンベロープ許可を裏付ける資金が減少します。


### 8.2 エンベロープコミットメント


同じ開いているプランが、エンベロープに割り当てられた経費アカウントをターゲットにしている場合:


```text
EnvelopeCommitment coordinate
= BudgetCycle x observedThrough x EnvelopeId x Commodity
```


その金額により、別の購入に使用できる封筒のお金が減ります。


### 8.3 使い捨て封筒以外の定額支払い


家賃、税金、または公共料金の支払いは、使用可能な封筒に属さずに裏付けプールから引き出すことができます。


このようなプランでは、プール コミットメントは作成されますが、エンベロープ コミットメントは作成されません。


これはユーザーの要件に必要です。つまり、予定された固定支払い用に予約されているお金は、単に支払いが使用可能な封筒セットの外にあるというだけの理由で、自由に割り当て可能であるように見せてはなりません。


## 9. 正確な式の候補


最初の候補式は次のとおりです。


```text
gross pool backing
= exact balance of eligible Asset accounts through observedThrough

available pool backing
= gross pool backing
- open pool commitments

ledger remaining
= entitlement through observedThrough
- consumption through observedThrough

available envelope remaining
= ledger remaining
- open envelope commitments

unallocated
= available pool backing
- sum of available envelope remaining for envelopes backed by the pool
```


すべての用語は商品ごとに独立しています。評価や換算は行われません。


これらの式は、後の実装のための観察です。依然として、明示的な許可、調整、およびエラー契約が必要です。


## 10. 最小限の数値観測


### 10.1 同一プールのエンベロープ支払い


初期状態:


```text
bank Asset balance             100
Food ledger remaining           80
open Food payment commitment    30
```


お支払い前:


```text
available pool backing      = 100 - 30 = 70
available Food remaining    =  80 - 30 = 50
unallocated                 =  70 - 50 = 20
```


支払いが実際になった後:


```text
bank Asset balance              70
Food ledger remaining           50
open commitment                  0
available pool backing          70
available Food remaining        50
unallocated                     20
```


計画の予約は、実際の証拠が実際の資産と残りのエンベロープを減らし始めたときに正確に消えます。保護された残りは、遷移全体にわたって 20 のままです。


### 10.2 封筒外の定額支払い


```text
bank Asset balance              100
open rent commitment             60
sum available envelope money     30
```


それから：


```text
available pool backing      = 100 - 60 = 40
unallocated                 =  40 - 30 = 10
```


予約された家賃を別の封筒に再度付与することはできません。


### 10.3 封筒側のみに適用される予約


不完全な式は次のようになります。


```text
pool backing                     100
Food remaining after reserve      50
calculated unallocated             50
```


未割り当ては、単に予定された支払いが記録されたという理由だけで 20 から 50 に増加します。これにより、予約された量が新しく割り当て可能であるように誤って見えます。


同一プールのエンベロープ支払いの場合、コミットメントはプールの自由とエンベロープの自由の両方に影響を与える必要があります。


### 10.4 プールサイドのみに適用される予約


別の不完全な式は次のようになります。


```text
available pool backing            70
Food remaining                     80
calculated unallocated            -10
```


システムは不足を報告しますが、食料封筒は 80 個すべてが利用可能であることをユーザーに伝えます。 2 つの見解は互いに矛盾します。


### 10.5 実際の完了の複製


2 つの実際のトランザクションに同じ `plan_id` が含まれる場合、予約を削除して両方の支払いを合計すると、重複した完了の証拠が隠蔽されます。


リレーションはフェイルクローズするか、未完了の競合状態を公開する必要があります。黙って実際の 1 つを選択したり、両方を追加したりしてはなりません。


### 10.6 期限を過ぎても支払いがまだ残っている


予定された引き落としの期限が昨日だったが、まだ実績に表示されていないとします。


```text
planned date        < observedThrough
completion state    open
bank money          still expected to leave
```


日付だけではコミットメントが終了したことを証明するものではありません。単に期限を過ぎているという理由だけでこの行を除外すると、銀行や家計がまだ留保している資金が解放される可能性があります。


## 11. 完了移行と二重カウント防止


必要な遷移はリレーショナルです。


```text
OPEN Plan
  + no valid Actual with PlanId
  -> commitment is active

OPEN Plan
  + exactly one valid matching Actual with PlanId
  -> relation is completed
  -> commitment is inactive
  -> Actual affects Asset balance and Consumption
```


一致する実績がすでに同じ経済的能力を削減した後は、計画額を予約したままにしてはいけません。


したがって、同じ ID によって両方のエラーが防止されます。


```text
before completion  forgetting to reserve
 after completion  reserving and posting at the same time
```


キャンセルは、将来のライフサイクルの個別の移行です。明示的なキャンセルの証拠が存在しない限り、実際の不在だけでは、アクティブなコミットメントとキャンセルされたプランを区別することはできません。


## 12. 必要な位置合わせ座標


後のコミットメント計算では、少なくとも以下が必要です。


```text
BudgetCycle
observedThrough
PlanId
planned date
from Account
To Account
exact Amount
completion relation through observedThrough
```


射影では次のことが追加されます。


```text
from Account -> BackingPoolId, when defined
to Expense Account -> EnvelopeId, when defined
EnvelopeId -> BackingPoolId
```


計算では、次のような不一致を保持する必要があります。


- プランは、宛先エンベロープが使用するものとは異なるプールから取得します。

- 計画は非プール資産から引き出します。

- 計画は負債または別の非資産勘定から引き出します。

- 計画は未割り当ての経費を対象としています。

- 計画に重複または曖昧な実際の完了の証拠がある。

- 計画商品が認められたアカウントまたは完了証拠と一致しません。


これらのケースは証拠であり、関係をでっち上げるための誘いではありません。


## 13. 保管境界


観察された bqn-ledger 行の形状は、小さな追加指向の TSV が以下を実行できることを示しています。


```text
planned date
memo
from Account
to Account
exact amount
commodity metadata
plan_id
```


h-kernel は後に `plan.tsv` アダプターを採用する可能性がありますが、この観察は列の順序、メタデータ構文、繰り返し構文、またはキャンセル ストレージを修正するものではありません。


推奨される方向は次のとおりです。


```text
external Plan rows
-> strict admission
-> typed Plan values
-> completion relation
-> commitment projections
```


バッキングは、生の TSV 列ではなく、型指定された計画の証拠に依存する必要があります。


## 14. 実装順序の修正


バッキング パスは、次の有限スライス内で進む必要があります。


1. `observedThrough` セマンティクスを Entitlement、Consumption、および Remaining に追加します。

2. 型付きのコミット済み送信プランと永続的な `PlanId` 境界を導入します。

3. `observedThrough` を通じて、純粋な計画と実績の完了関係を導入します。

4. オープン、完了、重複、およびあいまいな状態を明示的に保存します。

5. 有効なオープンプランを正確なプールコミットメントに投影します。

6. 適格なオープンプランを正確な範囲のコミットメントにプロジェクト化します。

7. 利用可能なプール バッキングと利用可能な残りのエンベロープを導出します。

8. プールおよび商品ごとの未割り当てと不足を導き出します。

9. プレゼンテーションとアダプターは、ドメインの結果が安定した後でのみ追加します。


裏付けの実装は、ステップ 1 から直接ステップ 7 にジャンプするべきではありません。


## 15. 保留された質問


この観察は次のことを決定するものではありません。


- 承認されたすべてのプランがコミットされるか、それとも別の種類のコミットメントが存在するか。

- キャンセルの証拠がどのように保存されるか。

- 期限を過ぎたオープンプランが常に無期限に予約されるかどうか。

- 選択したサイクルを超えたコミットメントで現在のサイクルの資金が確保されるかどうか。

- 繰り返しテンプレートが個々の永続的なプラン ID を生成する方法。

- 部分的な補完がサポートされているかどうか。

- 1 つの計画が、意図的に異なる複数の実際のトランザクションによって完了するかどうか。

- 計画された賠償責任の支払いまたはクレジットカードでの購入が支援にどのように影響するか。

- エンベロープとは異なるプールからの計画図面がどのように調整されるか。

- ユーザーがコミットメントについて知った時期を計画ソースに記録するかどうか。

- 現時点の履歴レポートで、後で入力された計画行を再現できるかどうか。

- 正確な `plan.tsv` 構文;

- または UI とエディターのワークフロー。


## 16. 観察の結論


銀行口座の残高と自由に割り当てられるお金は同じ事実ではありません。


未払いの確約支払いは中間の状態を占めます。


```text
not yet Actual
not merely speculative
already unavailable for reuse
```


bqn-ledger は、便利な `plan_id` ライフサイクルと個別のオープン プラン リザーブを示します。 h-kernel は、隣接する実装を変更せずにコピーすることなく、そのアイデンティティと証拠の規律を独自のプールベースの予算モデルに組み込む必要があります。


したがって、Backing への将来の一貫した入力は次のようになります。


```text
aligned Remaining through observedThrough
+ exact Asset balances through observedThrough
+ valid open pool commitments
+ valid open envelope commitments
+ BackingPool policy topology
= available backing and available envelope money
```


次の実装では、引き続き観測範囲の調整が行われます。次の有限所有者は、裏付け演算自体ではなく、コミットされた計画承認およびライフサイクル証拠を型指定する必要があります。
