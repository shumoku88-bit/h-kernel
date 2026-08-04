# 報告書検証契約書


ステータス: レポート作業で必須
契約の基準日: `2026-07-31`


## 目的


レポート作業は、再現可能で観察可能な成果物と照らし合わせてレビューする必要があります。集中的な単体テストでは、完全なレポート契約は確立されません。


検証境界は次のとおりです。


```text
fixed source SHA + immutable input + explicit observation date
  -> h-kernel binary
  -> complete plain-text output
  -> approved golden observation
```


型指定されたドメインとレポート モデルには、独自の会計セマンティクスがあります。スナップショットはレンダリングされたコントラクトを検証します。ドメインの不変条件をオーバーライドしません。


## 検証レイヤー


### セマンティックフィクスチャゲート


`tests/fixtures/report-contract.journal` は、手動で監査できるように意図的に十分に小さくなっています。これには正規の現在日以降のトランザクションが含まれるため、期間の境界は表示されたままになります。


```sh
sh ./report-verify --fixture
```


### 凍結合成コーパスゲート


`tests/corpus/synthetic-v1/` は、名前、日付、金額、アカウント、ポリシー値がこのプロジェクトのために作成された不変の公開専用コーパスです。


```sh
sh ./report-verify --corpus
```


このコーパスは、複数の口座、複数転記トランザクション、JPY と USD、境界時点、複数の暦月、トランザクション全体の最近のトランザクションをカバーしています。そのマニフェストはファイルのアイデンティティを修正し、レビューされたゴールデン レコードは完全な出力を記録します。


### 外部private正規世帯観察


明示設定されたprivate BQN互換source setは、ローカルでread-onlyに観察できます。


```sh
./report-real-snapshot
```


`HKERNEL_LEDGER_DATA_DIR`またはGit管理外の`ledger-data.local`でsource directoryを選択します。出力は無視された`.report-artifacts/real-household-report/`に残し、リポジトリのgoldenにはしません。CIはprivate sourceへ接続しません。


### オプションのローカルジャーナル観察


変化するユーザー所有のジャーナルは、ゴールデンオラクルやリポジトリの入力となることはできません。クラッシュ、セクションの欠落、実際のレイアウト、パフォーマンスについては、引き続きローカルで観察される可能性があります。


```sh
sh ./report-verify --observe /path/to/local.journal 2026-07-31
```


結果として得られる単純なレポートと証拠は、`.report-artifacts/` に書き込まれます。証拠には、ソース SHA、ジャーナル ハッシュ、観察日が記録されます。


fixtureとcorpusの固定検証では、`HKERNEL_REPORT_CONFIG`と`HKERNEL_LEDGER_DATA_DIR`をunsetし、分離された作業directoryからbinaryを実行します。ローカルの運用構成では固定契約を変更できません。`report-real-snapshot`だけが明示されたprivate sourceを読みます。


## 黄金律


- `tests/golden/report-contract.txt` は小さなセマンティックフィクスチャを修正します。

- `tests/golden/report-corpus-synthetic-v1.txt` は合成コーパスを修正します。

- ゴールデン アップデートは、動作の変更に応じてレビューする必要があり、単に CI をグリーンにするためだけに再生成することはできません。

- コーパス ディレクトリは不変です。置換では、新しい合成コーパス バージョンが使用されます。

- 単体テストに合格しただけでは、完全に締結された契約が変更されていないという証拠にはなりません。


## PRの証拠


レポート PR には次のことを記載する必要があります。


1. 正確なコマンド、ソース SHA、入力 ID、および観察日。

2. レポートのセクションが変更されました。

3. 報告書のセクションは変更されていないことが確認されました。

4. フォーカスされた、フィクスチャ、コーパス、完全なビルド/テスト、およびベンチマーク結果。
