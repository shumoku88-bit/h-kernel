# 予算裏付けの観察 — 座標および水平ゲート


## 1. ステータス


このドキュメントは、正確な予算残りが導入された直後のリポジトリの状態を記録します。


これは観察であり、裏付けの実施ではなく、負債に裏付けられた支出に関する最終決定でもありません。その目的は、どの意味がすでに入力されているか、どの意味が散文でのみ説明されているか、およびバッキング計算を信頼できる前にどの座標を明示する必要があるかを識別することです。


観察されたメインコミット:


```text
fc908345f936d2f79fb42c0ed2b3225d7bd771e0
```


## 2. 有限の質問


> h-kernel は現在、budget backingについて何を知ることができ、pool balance、Unallocated、またはshortageを計算する前にどのsemantic gapを埋める必要があるか?


有限の範囲は既存の家計モデルのみです。


- 検証された仕訳帳の会計事実、

- `BudgetPolicy` バックプールメンバーシップ、

- サイクルローカル資格、

- サイクルローカル消費、

- 正確な残り、

- そして正確な口座残高。


この観察では、バッキング、未割り当て、不足、ペーシング、レンダリング、CLI ロード、負債配分、評価、または換算は実装されていません。


## 3. 観察された発生源


この観察は、次のライブ リポジトリ所有者に基づいています。


```text
src/HKernel/Budget/Policy.hs
src/HKernel/Budget/Consumption.hs
src/HKernel/Budget/Entitlement.hs
src/HKernel/Budget/Remaining.hs
src/HKernel/Engine/Facts.hs
src/HKernel/Account.hs
src/HKernel/Report.hs
src/HKernel/Envelope.hs
tests/EnvelopeBudgetSpec.hs
docs/BUDGET_MODEL_OBSERVATION.md
README.md
```


## 4. 現在の型付きパイプライン


現在のバジェット カーネルには、Remaining で出会う 2 つの独立したパスがあります。


```text
BudgetHistory
  -> cycle-local BudgetEntitlement

Journal Expense postings in one BudgetCycle
  + AccountValidatedBudgetPolicy
  -> cycle-local BudgetConsumption

BudgetEntitlement
  - BudgetConsumption
  -> BudgetRemaining
```


Remaining の計算所有者は以下を検証します。


- `BudgetCycle`と等しい、

- 等しいエンベロープ ID セット、

- そして正確な座標方向の減算。


結果のセマンティック座標は次のようになります。


```text
BudgetCycle × EnvelopeId × Commodity
```


現在、バッキング結果タイプまたはバッキング計算所有者が存在しません。


## 5. すでに確立されているポリシー


`BudgetPolicy` は、将来のバッキング所有者が必要とするトポロジをすでに定義しています。


```text
Asset account -> BackingPoolId
EnvelopeId    -> BackingPoolId
```


現在のポリシーの境界では、次の事実が確立されています。


1. すべてのバッキング プールには、少なくとも 1 つの構成されたアカウント ID があります。

2. `AccountValidatedBudgetPolicy` を構築する前に、構成されたすべてのバッキング アカウントを `Asset` として宣言する必要があります。

3. 1 つのアセット アカウントが 2 つのバッキング プールに属することはできません。

4. 1 つのバッキング プールに複数のアセット アカウントを含めることができます。

5. 複数の使用可能なエンベロープが同じバッキング プールを参照する場合があります。

6. エンベロープは、欠落しているバッキング プールを参照できません。

7. すべてのバッキングプールの外にある資産はジャーナルファクトとしては引き続き有効ですが、予算トラッカーの外にあります。

8. Liability Accountは、現在のpolicy境界を通じてBacking poolに入ることができません。


これらは構造的な事実にすぎません。ポリシーでは転記の検査や残高の計算は行いません。


## 6. 会計エンジンがすでに確立しているもの


`HKernel.Engine.Facts` は、次の 3 つの観点から正確な口座残高を導き出すことができます。


```text
all Journal entries
one inclusive DateRange
all entries through one Day
```


ポイントインタイムのバッキングの場合、関連する既存のクエリは概念的には次のとおりです。


```text
accountBalancesThrough observedThrough journal
```


口座残高には、転記の元帳記号が保存されます。エンジン:


- マイナスの資産残高を固定しません。

- マイナスの資産残高を拒否しません。

- 商品を変換しません。

- 資産と負債の意味を組み合わせたものではありません。


`HKernel.Report.balanceSheetAsOf` は元帳記号に資産行も残します。負債および資本の信用記号は、貸借対照表の表示に対してのみ正規化されます。そのプレゼンテーション ルールは、再利用可能なバッキング ルールではありません。


## 7. 以前の Envelope 拡張ではバッキングが計算されません


前に入力した `HKernel.Envelope` 拡張機能は、次の名前の見出しをレンダリングします。


```text
Envelope & Backing
```


ただし、そのドメイン計算では次の情報のみが読み取られます。


- 外部エンベロープ割り当て、

- 経費勘定の割り当て、

- 範囲内の経費転記。


計算します:


```text
Entitlement
Consumption
Remaining = Entitlement - Consumption
```


資産残高、バッキングプールのメンバーシップ、負債残高、または未割り当ての残高を読み取ることはありません。


したがって、古い見出しは既存の Backing セマンティック コントラクトの証拠ではありません。これは、Backing 計算の前に到着したプレゼンテーション名です。


## 8. 欠落しているセマンティック結合


最初の予算観察では、プールの利用可能な残高が次のように説明されます。


```text
pool available balance
= current exact balance of eligible Asset accounts in the pool
```


未割り当てについては次のように説明されています。


```text
unallocated
= pool available balance
- sum of remaining spendable envelopes backed by that pool
```


算術演算はすでに利用可能です。足りない部分は座標の調整です。


プール残高は特定時点の事実です。


```text
observedThrough × BackingPoolId × Commodity
```


現在の `BudgetRemaining` はサイクルローカルのみです:


```text
BudgetCycle × EnvelopeId × Commodity
```


現在、Remaining への両方の入力は、選択されたサイクル全体を監視しています。


- `BudgetEntitlement` は、有効日が予想観察日より後の変更を含む、サイクルに属するすべての許可された `BudgetChange` を合計します。

- `BudgetConsumption` は、予想観察日以降の転記を含む、半オープンサイクル内のすべての経費転記を選択します。


どちらの結果にも `observedThrough` 日は含まれていません。したがって、資産残高は早い日に観察されますが、残存には将来の配分変更とその後の経費転記が含まれる可能性があります。


値は機械的に減算できますが、必ずしも同じ世界を参照するとは限りません。


## 9. 最小限の数値観測


以下のすべての例では、正確な整数が使用されています。これらはまだ提案されたテスト フィクスチャではありません。これらは、候補となる式の意味を明らかにします。


### 9.1 整列された初期状態


1 つのコモディティと 1 つのバッキング プール:


```text
pool Asset balance     100
sum envelope Remaining  80
Unallocated             20
```


これは、予算モデルで記述される通常の保護された残余です。


### 9.2 調整された期間を使用した割り当てられた購入


30 個の購入は使用可能なエンベロープに割り当てられ、そのエンベロープのバッキング プールから支払われます。


```text
before: Asset 100, Remaining 80, Unallocated 20
after:  Asset  70, Remaining 50, Unallocated 20
```


実際の資産残高と支出許可の両方が同じ量だけ減少するため、この計算式は未割り当てを安定に保ちます。


### 9.3 ホライズンが調整された未割り当ての購入


30 個の購入はプールから支払われますが、使用可能な封筒には割り当てられません。


```text
before: Asset 100, Remaining 80, Unallocated  20
after:  Asset  70, Remaining 80, Unallocated -10
```


これにより、不足の証拠 10 が生成されます。結果は既存のモデルと一致します。つまり、名前付きエンベロープを削減せずに実際のバッキングが落ちました。


### 9.4 以前の資産残高と混合した将来の経費転記


同じサイクルの後半で将来の割り当て購入 30 がすでに存在しますが、その購入の前に裏付け残高が観察されているとします。


以前の観察を修正します:


```text
Asset through today             100
Remaining through today          80
Unallocated through today        20
```


現在のフルサイクルの残高と今日の資産残高を組み合わせたもの:


```text
Asset through today              100
Remaining including future spend  50
calculated Unallocated             50
```


見かけの保護された残りが 20 から 50 に増加するのは、単に 2 つのホライズンが混合されたためです。これは丸めの問題や算術上の欠陥ではありません。欠落している座標です。


### 9.5 以前の資産残高と混合した将来の予算変更


20 というプラスの資格変更が同じサイクルの後半で有効になると仮定します。


以前の観察を修正します:


```text
Asset through today                100
Entitlement through today           80
Consumption through today            0
Remaining through today             80
Unallocated through today           20
```


現在のフルサイクルの権利と今日の資産残高を組み合わせたもの:


```text
Asset through today                 100
Entitlement including future change 100
Consumption through today              0
calculated Remaining                 100
calculated Unallocated                 0
```


将来の付与は、発効日より前に今日の保護された残りを消費します。したがって、消費量に 1 日だけを追加しても、予算の状態は調整されません。資格では同じ観察期間を使用する必要があります。


### 9.6 別のバッキングプールから支払われた割り当て済みの購入


食品は `operating` に属し、購入は `savings` の資産から支払われるとします。


購入前に:


```text
operating Asset                    100
operating Food Remaining            80
operating Unallocated               20

savings Asset                      100
savings envelope Remaining total     0
savings Unallocated                100
```


貯蓄から支払われた 30 の食料購入後:


```text
operating Asset                    100
operating Food Remaining            50
operating Unallocated               50

savings Asset                       70
savings envelope Remaining total     0
savings Unallocated                 70
```


未割り当ての合計は 120 のままですが、明示的な予算の移動なしで 30 が貯蓄プールから運用プールに移動します。


現在の消費量は、経費転記とそのエンベロープ ルートを観察します。トランザクションの対応する資産を検査したり、属性を特定したりすることはありません。トランザクションには複数の対応する転記が含まれる場合もあるため、後で適用する一般的な 1 つの対応するショートカットはありません。


これによってプール残高の監視が妨げられることはありません。これは、プールレベルの「未割り当て」が、割り当てられた各購入ごとに安定した状態を維持するのではなく、プール間の資金調達の不一致を引き起こす可能性があることを意味します。リポジトリはまだその証拠に名前を付けていませんし、そのような支出に明示的なプール転送が必要かどうかも決定していません。


### 9.7 責任付き購入


30 の割り当てられた購入によって負債が増加し、バッキングプール内の資産は減少しないと仮定します。


```text
before: pool Asset 100, Remaining 80, Unallocated 20
after:  pool Asset 100, Remaining 50, Unallocated 50
```


この式では、負債を負った後はさらに多くの未割り当てが報告されます。現在のポリシーでは、意図的に負債勘定科目をバッキング プールから除外していますが、消費では、対応する負債が負債である経費転記を引き続き観察できます。


したがって、負債残高を無視するだけでは、負債に裏付けられた支出を一貫性のあるものにすることはできません。その治療は今後の個別の決定として残されています。


### 9.8 マイナスの資産残高


会計エンジンは、マイナスの資産残高を保持する可能性があります。


```text
pool Asset balance      -10
sum envelope Remaining    0
Unallocated             -10
```


正確な値を保存すると、不足の証拠が生成されます。それをゼロに固定すると、会計上の証拠が隠蔽されてしまいます。これを拒否すると、報告可能な財務状態が計算上の失敗に変わります。


リポジトリは現在、これらのポリシーの中から明示的に選択しませんが、既存の正確なバランスのスタイルでは、サイレント クランプよりも保存が優先されます。これは現在の境界からの推論であり、まだバッキング契約ではありません。


## 10. バッキングは個々のエンベロープではなくプールに属します


複数のエンベロープが 1 つのバッキング プールを共有する場合、リポジトリには特定のアセット ユニットを特定のエンベロープに割り当てるポリシーがありません。


例えば：


```text
assets:smbc -> operating -> Food / Tobacco / Other
```


次の値は明確に定義されています。


```text
operating Asset balance
sum of Remaining for operating envelopes
operating Unallocated
operating shortage
```


「食料品は三井住友銀行の12,000円で裏付けされている」といった個別の価値は、現在の政策では決定されません。これを作成するには、存在しない割り当てルールまたは優先順位ルールが必要になります。


したがって、自然な初版粒子は次のようになります。


```text
BackingPoolId × Commodity
```


エンベロープ レベルの残りは、ポリシーを通じてそのプールに結合された別の結果のままになります。


## 11. 地平線の境界候補


### 11.1 全サイクルのバックアップ


フルサイクルの権利付与と消費を使用して、サイクルの最終日までの資産残高を観察します。


これは内部的に調整されており、完了したサイクルのレポートをサポートする可能性があります。現在のインサイクル トラッカーはサポートされていません。今日の状態として公開された場合、同じサイクルからのその後の予算変更と仕訳帳への転記が含まれることになります。


### 11.2 明示的なオブザーブスルー裏付け


`observedThrough` 日を 1 つ選択し、次の目的で一貫して使用します。


```text
Budget changes effective through observedThrough
Asset balances through observedThrough
Expense consumption through observedThrough inside the selected cycle
Remaining derived from those aligned inputs
Backing and Unallocated publication
```


これは、既存のポイントインタイム レポートのアーキテクチャと、意図されたインサイクル日次トラッカーと一致します。バッキングが実装される前に、予算結果チェーンが観察期間を保持する必要があります。


### 11.3 修飾されていない「最新のジャーナル」の裏付け


観察日を公開せずに、入力ファイルに現在存在するすべての予算変更と投稿を使用します。


これにより、結果は明示的な意味座標ではなくファイルの内容に依存します。これは再現可能な現時点のレポートと互換性がないため、非表示のデフォルトとして採用すべきではありません。


## 12. 観察された実装ゲート


裏付け演算は次に欠けているプリミティブではありません。 `addBalance`、`subtractBalance`、口座残高の削減、ポリシーメンバーシップ、および正確な商品の分離はすでに存在します。


次に欠けているドメインの事実は次のとおりです。


```text
which day has this budget state been observed through?
```


バッキング所有者が導入される前に、1 つの有限スライスで、権利、消費、および残りについて明示的かつ調整された観察範囲を確立する必要があります。


その後、後からバッキング所有者は次のような証拠を要求することができます。


```text
selected BudgetCycle
selected observedThrough Day
AccountValidatedBudgetPolicy
Journal
BudgetRemaining for the same cycle and observation horizon
```


経費転記を再解釈したり、封筒レベルの資金割り当てを作成したりすることなく、プールレベルの正確な資産残高を公開します。


プール間および負債担保支出は、推測された取引対応ルールによって修正されるのではなく、プールレベルの結果に表示されたままである必要があります。


## 13. 最初のバッキングスライスにはすでに十分な事実がある


ホライズン アライメントが存在すると、リポジトリは次の初期制約をすでにサポートします。


1. ポリシーによって`Asset`として検証されたアカウントのみがプールに貢献します。

2. すべてのプール外の資産は除外されます。

3. プール残高は正確であり、商品ごとに分離されています。

4. 複数の資産アカウントを 1 つのプール座標に減らすことができます。

5. いくつかのエンベロープは、残りを 1 つのプール座標に減らすことができます。

6. マイナスの天びんを静かにクランプしてはなりません。

7. 負債残高は資産残高と暗黙的に相殺されません。

8. 市場評価や商品変換は行われません。

9. 不足は、権利または残りを書き換えるのではなく、証拠として残ります。

10. トランザクションの相手方の構造はプールの属性に推測されません。


項目 6、7、および 10 は、実装の開始時に明示的な名前付きコントラクトが依然として必要ですが、追加の算術表現は必要ありません。


## 14. 保留された質問


この観察は次のことを決定するものではありません。


- マイナスの資産残高がバッキング値として受け入れられるか、値とともに別の診断として表示されるか、

- 異なるバッキングプールから支払われた割り当て済みの購入に名前を付けるか、または調整する方法

- プール間の支出に明示的なプール転送が必要かどうか、

- 複数の資産または負債との取引が資金調達の証拠にどのように影響するか、

- 負債に裏付けられた支出が利用可能な予算をどのように変化させるか、

- 信用制度が明示的な裏付け源となり得るかどうか、

- 保留中またはスケジュールされたトランザクションが `observedThrough` とどのように相互作用するか、

- 将来の日付の雑誌投稿をどのように表示するか、

- 不足とマイナスの未割り当てが 1 つの表現であるか 2 つの予測であるか、

- プールが現在アクティブなエンベロープを意図的にバックアップできないかどうか、

- 商品間の評価または交換、

- 個々のアセットからエンベロープへの帰属、

- または UI とレンダリングの選択肢。


## 15. 観察の結論


リポジトリには、Backing の構造グラフと、それを削減するために必要な正確な演算がすでに含まれています。


決定的に欠けている境界は、さらなる減算ではありません。これは、予算の変更、会計残高、経費消費全体にわたる共有された時点の調整です。


```text
BudgetCycle
+ observedThrough
+ budget changes effective through that day
+ Expense postings through that day
+ exact Asset balances through that day
+ pool membership
= coherent input for Remaining and Backing
```


これらの視野が一致すると、現在のモデルがどの資産ユニットがどの封筒に資金を提供したかをすでに知っているかのように装うことなく、プール間および負債で資金調達された活動を証拠として公開できます。


したがって、次の実装では、`HKernel.Budget.Backing` を追加する前に、予算観測範囲のセマンティクスを確立する必要があります。
