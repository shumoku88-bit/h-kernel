# 債務ポジション設計スケッチ

ステータス: アクティブな設計スケッチ  
更新日: 2026-08-04

## 目的

この文書は、個別のLiability Accountを家計上の債務ポジションとして選択し、元本の増減、残高、将来の返済Planを説明するprojectionの未確定設計を所有する。

これは実装済みの契約でも、着手順を固定するTODOでもない。現在の会計核がすでに保持しているLiabilityの事実と、将来必要になり得る家計policy／projectionの境界を記録する。

## CURRENT

- `AccountRegistry`は、完全なネストを持つAccount identityを通常のAccountとして保持する
- `Liability`という会計上の型はAccount宣言が所有し、`loan`、`payable`などAccount名の一部から推測しない
- Trial Balance、Account balance、Balance Sheetは、家計上の債務ポジションへ選択されるかどうかとは独立して全Liability Accountを保持する
- 元金返済はAssetからLiabilityへの移動として記帳でき、利息や手数料は必要に応じて別のExpense Postingとして同じTransactionに置ける
- 将来の元金返済はPlanとして表現できるが、open Planは現在のLiability残高を減らさない
- Plan完了は耐久的なPlan identityとActual側の完了証拠で解決し、説明、類似金額、Account名、日付から推測しない

## DIRECTION

家計上の債務ポジションは、すべてのLiability Accountを機械的に並べるReportではなく、明示的なpolicyが選んだAccountを対象とする。

```text
AccountRegistry
+ explicit household liability policy
+ Actual Journal facts
+ open principal-payment Plans
+ observation Period
  -> LiabilityPositionProjection
```

policyは少なくとも次を明示する。

- 公開対象のLiability Account
- 決定論的な公開順
- 必要であれば表示用label
- AccountごとのCommodity条件

policy ownerはAccount名のprefix、貸し手を思わせる文字列、残高、memoから対象を推測しない。

## Admission

policyは共有`AccountRegistry`へ照合する。

次はReport構築前に拒否する。

- 未宣言Account
- LiabilityではないAccount
- 重複したmembership
- policyが要求するCommodity evidenceとの不一致

移行中のadmissionやconverterは、現在のAccount identityを完全に保持する。Account名を変更したり、Account名から家計上の目的を生成したりしない。

## Accounting semantics

### 元金

元金の増加と返済は、Liability残高の変化として観察する。

```text
借入       Asset増加 + Liability増加
元金返済   Asset減少 + Liability減少
```

元金返済をExpenseへ読み替えない。

### 利息と手数料

利息や手数料がある場合は、元金とは別のExpense Postingとして明示する。一つの支払いTransactionに元金、利息、手数料が共存しても、それぞれの意味を潰さない。

### 一時的な債務

短期間で精算されるpayableも、未払いの間は本物のLiabilityである。通常の会計Reportから消さない。家計の長期的な債務ポジションに含めるかどうかだけを明示的policyが決める。

### Plan

将来の元金返済Planは、正確に一つのLiability Accountをdestinationとする必要がある。

open Planは将来必要な資金の証拠にはなり得るが、Actual JournalのLiabilityを先に減らさない。完了は耐久的なPlan-to-Actual evidenceで解決する。

## Projection sketch

AccountとCommodityごとに、少なくとも次を別の値として保持する案がある。

- Period開始時点のsigned Liability balance
- Period内の元本増加
- Period内の元本返済
- Period終了時点のsigned Liability balance
- 基礎の符号を変更しない、正の「負っている額」というpresentation projection
- open principal-payment Planとそのdurable identity
- Actual／Plan sourceのprovenance

すべての集計はCommodityを分離した正確な`Balance`上で行う。異なるCommodityを一つの合計へ暗黙に換算しない。ゼロ残高も、対象Accountが存在した証拠として必要なら保持する。

## QUESTION

- policyは一般Report policyとHousehold policyのどちらが所有するか
- 一部元金返済をどの粒度のevidenceとして公開するか
- 複数の分割払いPlanとActual完了をどのprojectionで対応させるか
- 借換えを旧Liabilityの決済と新Liabilityの発生として十分に説明できるか
- Planの取消、交換、再予定をどのlifecycle evidenceで表すか
- 元金、利息、手数料を一つの支払いからどのownerが分類するか
- fixed obligation、Daily Target reservation、Backingと将来返済Planをどう接続するか
- multi-commodity Liabilityに単一Commodity policyを要求するか、複数Commodityをそのまま許すか

## POSSIBLE SLICE

最初の有限なsliceは、実データやrendererを変更せず、合成fixtureだけで次を観察するものにできる。

1. 完全なnested Account identityを保持する
2. 期首残高、新規借入、部分元金返済、全額決済を分類せずに会計factとして集計する
3. 明示policyが選んだLiabilityだけをprojectionへ入れる
4. open PlanがActual残高を減らさないことを確認する
5. Commodity、符号、期間、provenanceを保持する

型付きpolicyとprojectionの意味が固まる前に、renderer、CLI、canonical household data、writer authorityを変更しない。

## Verification boundary

- 合成fixtureには個人名、実際の日付、実際の残高、実際の取引説明を使用しない
- Account選択、期首／期末、元本増減、表示符号、open Plan identityをfocused testで観察する
- bqn-ledgerとの比較を行う場合、text同一性ではなく意味上の差を記録する
- 意図しないcross-engine semantics差が残る間は、運用上のcutover根拠にしない
