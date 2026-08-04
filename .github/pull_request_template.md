## 概要

## 検証

- [ ] 対象を絞ったテスト
- [ ] `cabal build all`
- [ ] `cabal test all`
- [ ] 最終差分を確認した

## レポートの変更（該当する場合に完了）

- [ ] 変更前後に `sh ./report-verify --fixture` を実行した
- [ ] 変更前後に `sh ./report-verify --corpus` を実行した
- [ ] `sh ./report-verify --observe JOURNAL NEW_AS_OF` を実行した
- [ ] 意図的に変更したレポートセクションを列挙した
- [ ] 対象範囲外のレポートセクションが変更されていないことを確認した
- [ ] 設定済みの `all` と単独セクションのpayloadが同等であることを確認した
- [ ] 変更した契約またはステータスについて `docs/REPORT_VERIFICATION.md` を更新した
- [ ] goldenの変更を無批判に受け入れず、動作変更としてレビューした
- [ ] 全レポートパイプラインを変更した場合のベンチマーク証拠を記録した

## 残りの相違点
