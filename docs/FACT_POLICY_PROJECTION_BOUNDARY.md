# 事実、方針、予測の境界線


ステータス: アーキテクチャ上の決定
記録日: 2026-08-03


## 1. 目的


`h-kernel`は現在の家計Reportを完成させるprojectであると同時に、将来、次の意味を追加できる余地を失わないようにする。


- lot trackingとcapital gain;

- 個人事業の帳簿と活動別集計;

- 家事・事業按分;

- 固定資産、減価償却、売却、除却;

- 証憑と取引の参照関係;

- 年度・法域ごとの税務projection;

- Plan、Budget、correctionなどの履歴依存計算。


この文書は、それらを今実装するroadmapではない。将来の機能が必要になったとき、現在の会計核、Journal、Reportを全面的に作り直さず、隣接するtyped projectionとして追加できるための境界を定める。


短期のReport restoration queueは引き続き優先される。この文書を理由に、未完成のReport surfaceより先に将来機能の基盤工事を際限なく進めない。


## 2. 決定


永続的な意味を次の三つへ分ける。


```text
admitted facts and declarations
          +
effective-dated policy and decisions
          |
          v
rebuildable typed projections
```


- **Fact**は、起きた取引や明示的に記録された証拠を表す。

- **Declaration**は、Account identityやaccounting typeなど、Factを解釈するためにadmitされた参照証拠を表す。household policyとは区別する。

- **Policy / Decision**は、Factそのものではない分類、選択、割合、method、有効期間、観察条件を表す。

- **Projection**は、Fact、Declaration、Policyから純粋に導出されるBalance、Report、lifecycle state、schedule、tax viewなどを表す。


Projectionの都合でFactを書き換えない。導出可能なProjectionをcanonical sourceとして保存しない。保存またはcacheする場合も、元のevidenceから作り直せることを契約とする。


## 3. 事実境界


### 3.1 セマンティックグレインの保持


検証済みの会計Factは、少なくとも次の意味を失わない。


```text
Transaction boundary
Posting boundary
source order
transaction date
exact Amount and Commodity
Account identity
whole-transaction description
validation result
```


Posting-grain集計のためにTransactionを平坦化してよい。ただし、平坦化されたviewだけを唯一のFact ownerにしない。


現在の`AccountingFacts`がposting-grain `LedgerEntry`、whole `Transaction`、`AccountRegistry`を別々に保持している方向を維持する。内部表現は今後変えてよいが、異なるgrainを一つへ潰さない。


### 3.2 身元と出所は引き続き追加可能


将来の具体的なuse caseが要求したとき、次のようなidentityをnamed typeとして追加できる余地を残す。


```text
TransactionRef
PostingRef
SourceRef
EvidenceRef
CorrectionRef
AssetId
LotId
PlanId
```


すべてを先回りして今導入しない。identityは、具体的な関係を安全に表すfinite sliceで追加する。


一方、次の設計は避ける。


- source lineだけをdurable identityとして扱う;

- description、日付、金額の近似一致で関係を確定する;

- Report rowを元のPosting identityの代わりに使う;

- aggregation時にsource orderやTransaction boundaryを回復不能にする。


### 3.3 人間が編集可能なジャーナルは引き続き許可されます


この決定は、Journalをappend-only event storeへ変更するものではない。人が過去の記帳を修正できるplain-text Journalを維持できる。


ただし、将来correction relationや監査履歴を必要とする機能を追加する場合、projection内部の隠れた上書きではなく、明示的なtyped evidenceとして設計する。


したがって、`h-kernel`は厳格なevent sourcingを現在採用したとは主張しない。代わりに、event-likeな順序付きprojectionを後から構築できるだけのgrain、order、identity、provenanceを失わない。


## 4. ポリシーと意思決定の境界


Factへ次の意味を焼き込まない。


- FIFO、LIFO、specific identificationなどのbooking method;

- 家事・事業の割合と按分根拠;

- 減価償却method、耐用期間、事業利用割合;

- Assetをspendable、savings、investmentとして扱う判断;

- AccountやExpenseをEnvelope、business activity、tax categoryへ対応させる判断;

- 観察期間、サイクルルール、評価日;

- 年度・法域固有のtax treatment。


これらは別のadmission boundaryを持つPolicyまたはDecisionである。


時間によって意味が変わり得るPolicyは、現在値だけでなく有効期間を表せる形を優先する。


```text
PolicyId
validFrom
validUntil or open end
method / classification / ratio
basis
optional evidence references
```


すべてのPolicyに同じrecord shapeを強制しない。各domain ownerが必要なcoordinatesを型で表す。


## 5. 2 つの計算ファミリー


集計を一つのgeneric frameworkへ押し込まない。少なくとも二種類の計算を区別する。


### 5.1 可換還元


順序を変えても意味が変わらない会計集計は、単位元と結合演算を持つreductionとして表す。


```text
Posting
  -> singleton Balance
  -> Account / Commodity coordinate
  -> exact combination
```


例:


- 仕訳残高;

- 口座残高;

- 期間経費合計;

- 試算表;

- 商品別合計。


Haskellでは、domainに応じて`foldl'`、`foldMap`、`Map` combinator、`Semigroup`、`Monoid`などを使える。抽象を使う目的はloopを隠すことではなく、単位元、結合、canonical zero、Commodity separationを読めるようにすることである。


`Balance`へ`Monoid` instanceを必ず付けるという決定ではない。`emptyBalance`と`addBalance`の名前がdomainをより明瞭にする場合は、その明示性を保ってよい。


### 5.2 順序付けられた状態遷移


過去のstateと次のevidenceから新しいstateを作る計算は、source orderを保持するordered foldとして表す。


```text
initial state
  + ordered evidence
  -> next state
  + derived observations
```


例:


- lot inventoryとcapital gain;

- FIFO / LIFO予約;

- Plan lifecycleとPlan-to-Actual completion;

- 累積予算履歴;

- 修正チェーン;

- acquisition、transfer、disposalを伴うAsset state。


Haskellでは、たとえば次の形になり得る。


```haskell
foldl' applyEvidence initialState orderedEvidence
```


これは可換なBalance reductionとは異なる。順序をMap reductionや集合化で消さない。順序付き計算を`[LedgerEntry]`だけから実装せず、必要なTransaction grain、identity、policyを入力として要求する。


### 5.3 実際の法律がなければ統一しない


可換reductionとordered transitionを、見た目がどちらもfoldであるという理由だけで同じcustom frameworkへ統合しない。


共通抽象を導入する場合、次を説明できなければならない。


1. どのdomain lawを表すか;

2. order sensitivityを型またはAPIがどう守るか;

3. どのinvalid compositionを防ぐか;

4. 既存のnamed transformationより何を引けるか。


## 6. 将来の拡張形状


### 6.1 ロットとキャピタルゲイン


```text
validated Transaction
  -> admitted LotEvent
  + effective BookingPolicy
  -> ordered replay
  -> LotInventory + realised / unrealised gain projections
```


Capital gainだけをPosting総和から推測しない。取得、移動、売却のidentityとorderを保持する。


### 6.2 世帯/企業の割り当て


元の支払Factを事業割合に合わせて書き換えない。


```text
Expense Fact
  + AllocationDecision
      - effective period
      - ratio or allocation rule
      - basis
      - evidence references
      - rounding owner
  -> business / household projection
```


割合、根拠、roundingはDecision ownerが持つ。Account名へ`business-40-percent`のようなprojection都合を埋め込まない。


### 6.3 固定資産と減価償却費


```text
Acquisition Fact
  -> identified Asset
  + DepreciationPolicy
  + later disposal / correction evidence
  -> DepreciationSchedule
  -> period expense projections
```


購入Transactionを将来年度分へ直接分割してFactを作り変えない。取得Factと、年度ごとの償却projectionを区別する。


### 6.4 税金と申告の考え方


法域、年度、制度に依存する意味は、generic accounting coreの外側に置く。


```text
accounting and business facts
  + jurisdiction / tax-year policy
  -> tax classification and filing projection
```


`Money`、`Ledger`、generic balance reductionへ特定年度の税法を埋め込まない。申告様式や税務ruleが変わっても、元のFactと一般会計Reportが変わらない構造を目指す。


### 6.5 証拠と書類


領収書、請求書、契約、memoなどを将来結びつける場合、binary documentそのものを会計核へ埋め込まず、typed `EvidenceRef`と外部storage boundaryを使う。


Evidenceが存在しない場合と、まだlinkされていない場合を必要に応じて区別する。Report表示のためだけに証憑identityを捨てない。


## 7. 投影の再構築可能性


Projection、cache、snapshot、materialized viewを保存する場合、少なくとも次の観察条件へ戻れるようにする。


```text
source identity or hash
policy identity / effective version
projection implementation version
observation date or period
```


すべてを一つのglobal version fieldへまとめる必要はない。各projectionが、結果の由来と再生成条件を説明できることが重要である。


Golden outputとReport snapshotはverification evidenceであり、canonical accounting sourceではない。Goldenを更新して計算差を隠さない。


## 8. 現在の h-kernel の影響


この決定から、現在の実装には次の方針が導かれる。


1. `Journal`、validated `Transaction`、Posting grainを保持する。

2. `AccountingFacts`はinternalのまま進化させ、将来のprovenanceやtyped indexを今の公開APIで塞がない。

3. Balance系はexactなCommodity-separated reductionとして維持する。

4. lifecycle、lot、history系は、必要になったときordered projectionとして隣へ追加する。

5. Policy、Decision、税務classificationをTransactionやAccount名へ暗黙に埋め込まない。

6. Report row、rendered Text、snapshotをFact sourceとして逆利用しない。

7. source migrationは、この境界を守るために必要なfinite sliceだけを扱い、Report restoration queueを置き換えない。

8. 将来機能のためだけに、現在利用者が必要とするReport完成を延期しない。


## 9. 質問を確認する


将来のPRでは、必要に応じて次を確認する。


1. この変更はTransaction boundary、Posting grain、source order、provenanceを回復不能にしていないか。

2. 保存しようとしている値はFactか、Policyか、再生成可能なProjectionか。

3. Policyや税務判断をAccount名、description、Posting amountへ焼き込んでいないか。

4. 時間で変わる判断に有効期間が必要ではないか。

5. 計算は順序不変のreductionか、順序依存のstate transitionか。

6. 順序依存計算を平坦な`LedgerEntry`だけから作っていないか。

7. identity relationを日付、金額、memoの曖昧一致で代用していないか。

8. Projectionを元のFactとPolicyから作り直せるか。

9. 法域・年度固有のruleがgeneric accounting coreへ漏れていないか。

10. 新しい抽象は実在するdomain lawを表しているか。

11. 将来のprerequisiteが現在のReport-facing TODOを消していないか。


## 10. ノンゴール


この決定だけでは、次を実装または採用しない。


- 追加専用のイベント ストア。

- 厳格なイベントソーシングアーキテクチャ。

- ユニバーサルイベントタイプ;

- グローバル ID スキーム。

- ロット追跡;

- キャピタルゲインの計算;

- tax engineまたは申告書生成;

- 家事按分schema;

- 固定資産台帳または減価償却method;

- 証拠書類の保管;

- `AccountingFacts`のpublic API化;

- ソースデータのカットオーバー。

- Report roadmapの並べ替え。


これらは、実用上の必要と具体的なevidenceが現れた時点で、一つずつ独立したfinite sliceとして設計する。
