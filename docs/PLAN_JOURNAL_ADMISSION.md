# Plan Journal の受け入れ


ステータス: アクティブなアーキテクチャ契約
観察対象のmain: `a2c6068a4fcd4d409928e27a577a5d1dad7e3aee`
更新日: 2026-08-03


## 1. 目的


`plan.journal` は、日付が記載された将来のトランザクションの現在の h-kernel ソースです。これは、実績仕訳帳と同じ読み取り可能なトランザクション ブロック構文ファミリーを使用しますが、別個のファクト ソースのままであり、実際の口座残高は変更されません。


```text
plan.journal text
  -> canonical Journal validation
  -> unique plan-id per transaction
  -> whole identified Plan transaction
  -> incoming or outgoing role-flow classification
```


完全なトランザクションは保持されます。承認は、単に狭いレポート予測を満たすためにプランを 1 つのアカウント ペアまたは 1 つの金額にフラット化するものではありません。


## 2. ソースの受け入れ


プラントランザクションには、通常のバランスのとれた転記と、永続的な `plan-id` メタデータ キーが 1 つだけ含まれます。


```ledger
2026-08-12 Shared purchase
    ; plan-id: plan-shared-purchase
    expenses:food    600 JPY
    expenses:books   400 JPY
    assets:cash    -1000 JPY
```


正規の仕訳パーサーは、申告構文、転記構文、正確な金額、商品残高調整、およびトランザクション検証を所有しています。


`HKernel.Plan.Journal` は、プラン ID とロールフロー分類を追加します。ソースの承認が拒否されました:


- 仕訳構文または会計検証の失敗。

- `plan-id` を使用しないトランザクション;

- 無効な`PlanId`テキスト;

- 1 回のトランザクションで `plan-id` キーを繰り返した。

- 1 つの `PlanId` は複数のトランザクションを識別します。

- トランザクションとメタデータ ブロック数の不一致。


## 3. 役割フローの分類


分類はすべての投稿をこの座標にマップします。


```text
(declared Account type, quantity ordering relative to zero)
```


次に、完全な座標コレクションが、現在サポートされている形状に対してテストされます。


```text
Income(-) -> Asset(+)                    incoming
Asset(-)  -> Expense(+)/Liability(+)     outgoing
```


すべての座標が同じサポートされている形状に属している場合、両側の複数の転記は 1 つの計画トランザクションのままです。サポートされていない形状は `UnsupportedPlanRoleFlow PlanId` を生成します。分類では部分的な結果は公開されません。


受信した分類自体はサイクル アンカーを選択しません。その選択は、Household Report アダプターが所有する世帯ポリシーです。


## 4. 世帯レポートの統合


h-kernel アプリケーションは、`plan.journal` を読み取り、検証された `PlanJournal` を `buildHouseholdReportSurfaceFromPlanJournal` に渡します。


```text
PlanJournal
  -> AccountRegistry agreement with Actual Journal
  -> role-flow classification
  -> incoming cycle-anchor projection
  -> binary outgoing report projection
  -> completion evidence
  -> open current-cycle Plans
```


結果として得られるオープンな発信 Plan コレクションは、以下によって共有されます。


- 計画された取引;

- エンベロープオープンプランリザーブ;

- デイリーターゲットのオープン義務。


完了は、特定された実際のトランザクションからの明示的な `PlanId` 証拠によってのみ解決されます。日付、説明、金額の類似性、および口座名のパターンは完了の証拠ではありません。


## 5. 狭いレポート投影


ソース言語は現在の世帯レポート タイプよりも幅広いです。レポート投影は現在、次の出力形状のみを受け入れます。


```text
one Asset(-) Posting
+ one Expense(+)/Liability(+) Posting
-> CommittedOutgoingPlan
```


`ProjectedCommittedOutgoingPlan` が成功すると、識別されたソース トランザクション全体と、より狭いレポート値の両方が保持されます。


3 件以上のPostingを持つ有効な分類済みoutgoing Planでは、`PlanReportProjectionRequiresBinaryOutgoing PlanId` が生成されます。これによってソース プランが無効になることはありません。これは、現在のレポート予測が、その広範な取引にとって完全な意味を持たないことを意味します。


## 6. Actual との分離


計画トランザクションは将来の証拠であり、実際の会計事実ではありません。共有ジャーナル構文は、共有ライフサイクルまたはバランス効果を意味しません。


残高計算では実際のアクティビティとして `PlanJournal` が消費されません。実際のアイデンティティと計画のアイデンティティ、ロード、完了の証拠、および公開は分離されたままになります。


## 7. 廃止された互換性パス


世帯レポートは、`plan.tsv` を解析しなくなり、実行時またはその特性評価スイートで TSV と計画ジャーナルのサーフェスを比較しなくなりました。


private canonical directoryの`plan.tsv`はlegacy migration inputとして残ります。h-kernel Report入力ではなく、semantic parityを確認したsource migration sliceでretireします。


## 8. 検証


合成テストの対象範囲は次のとおりです。


- 着信および発信の役割フロー。

- サポートされていないフローの拒否。

- 完了および不明な計画参照の拒否。

- 予約範囲と商品契約。

- 現在のサイクルの選択とレポートの発行。


正規の世帯レポート テストでは、埋め込まれた `plan.journal` も直接読み取ります。検証は 2 番目の計画表現に依存しなくなりました。


## 9. 目標外と残りの作業


この境界はまだ次のことを行っていません。


- マルチポスト発信プランのレポート セマンティクスを定義します。

- 繰り返し、シリーズ、キャンセル、または置換を定義します。

- Plan editの日常interactionを完成させます。

- 完了メタデータにグラフを含めるようにします。

- `budget.journal` を紹介します。

- h-kernel Plan commandのend-to-end日常動作を検証します。

- legacy `plan.tsv`のsemantic parityと削除を確認します。


Journal ソースは、1 つのレポート投影よりも広い範囲を維持する必要があります。狭い消費者は、ソースを強制的に狭くするのではなく、まだ公開できない内容を明示する必要があります。
