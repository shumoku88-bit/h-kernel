# 債務ポジション設計スケッチ

ステータス: 未解決の設計観察

## 目的

この文書は、個別のLiability Accountを家計上の債務ポジションとしてどう選択し、Actualの残高・元本変化と将来の返済Planをどう同じprojectionで説明するか、という**まだ閉じていない問い**だけを所有する。

現在の会計law、Plan lifecycle、Daily Target、Backingを再定義しない。問いが閉じたら、確定したlawを該当するcurrent contract / architecture ownerへ移し、この文書は削除する。

## すでに確立している境界

この観察では次を再設計しない。

- Account identityと`Liability`型はcanonical Account declarationが所有し、Account名から推測しない
- ActualのLiability balanceはadmitted Journal factsから導出し、open Planで先に変更しない
- 元金、利息、手数料の会計Factは必要なPostingを分けて保持でき、Transaction metadataへ重複保存しない
- durable relationはdescription、金額、日付、Account名の近似一致で作らない
- Quantity / BalanceはCommodityを分離したexact arithmeticを保つ
- Daily TargetのPlan obligation / reservation semanticsは`DAILY_TARGET_POLICY.md`が所有する
- source Assetからのopen Plan funding commitmentとEnvelope claimの関係は`HOUSEHOLD_BACKING.md`が所有する

## Working hypothesis

家計上の債務ポジションは、全Liability Accountを機械的に並べるReportではなく、明示的policyが選んだAccountに対するprojectionとする案が有力である。

```text
AccountRegistry
+ explicit liability selection policy
+ Actual Journal facts
+ relevant open Plans
+ observation Period
  -> LiabilityPositionProjection
```

この形を採る場合も、policyはAccount identityを保持し、未宣言Account、非Liability Account、重複membership、要求するCommodity条件の不一致をfail closedに扱う。これはまだownerとsource shapeを確定したcontractではない。

## Open questions

1. **Policy owner**
   - Liability selectionは一般Report policyとHousehold policyのどちらが所有するか
   - membership、表示順、任意label、Commodity条件をどこまでpolicyに含めるか

2. **Principal evidence**
   - Liability残高変化から元本増加・部分返済・全額決済をどのgrainで説明するか
   - 一つの支払い内の元金・利息・手数料を、どのownerがprojection上で分類するか

3. **Plan lifecycleとの対応**
   - 分割返済Planと複数Actualをどのdurable evidenceで対応させるか
   - Plan取消、交換、再予定、部分完了をどう扱うか
   - 借換えを旧Liabilityの決済と新Liabilityの発生だけで十分に説明できるか

4. **Household capacityとの接続**
   - 将来返済Planをfixed obligation、Daily Target reservation、Backingのどこへ接続するか
   - 既存ownerの意味を重複させず、Liability projectionが何だけを参照すべきか

5. **Projection surface**
   - 期首/期末残高、期間内増減、open Plan、source provenanceのどこまでをstable surfaceにするか
   - signed accounting balanceと正の「負っている額」というpresentationをどう分離するか
   - multi-commodity Liabilityをpolicyで制限するか、Commodity別のまま公開するか
   - zero balanceになった対象Accountをpositionとして残すか

## 次の観察境界

次に進める場合も、最初はsynthetic fixtureだけでよい。

- nested Account identityを保持する
- 明示policyで選択したLiabilityだけを対象にする
- 期首/期末Balanceと期間内movementをCommodity別に観察する
- open PlanがActual balanceを変えないことを保つ
- identity、Plan relation、provenanceを曖昧一致で作らない

policy owner、Plan relation、projection grainが固まる前にrenderer、CLI、canonical Household data、writer authorityを変更しない。bqn-ledgerとの比較を行う場合もtext parityではなくsemantic differenceだけを観察する。
