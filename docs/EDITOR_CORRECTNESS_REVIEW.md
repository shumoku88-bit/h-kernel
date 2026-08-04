# h-kernel Editor correctness review

ステータス: 暫定レビュー記録  
Owner: h-kernel editor review  
Canonical: yes  
基準日: 2026-08-05  
基準main: `339d6af929bd3064a71288f5478504e87024d919`

## 1. 役割

E4からE7までのEditorを、build成功だけでなく、CLI invocation、typed intent、candidate admission、write effect、post-admission、identity、test coverageの連続した境界として点検する。

初版は一次レビューの指摘を暫定記録する。次のcommitで各項目をremote sourceとtestから再検証し、`confirmed`、`corrected`、`withdrawn`、`open question`のいずれかを付ける。修復順序は再検証後にTODOとして追加する。

## 2. Remote baseline

- main HEAD: `339d6af929bd3064a71288f5478504e87024d919`
- E4、E5、E6はmainへmerge済み
- open PR: #14 `spike(editor): Brick Actual add preview TUIを追加する`
- #14 head: `f8d2cbadcbea6975bbbd13c990b2afeaa3637070`
- #14はE7完了ではなくActual add read-only preview spike

## 3. 暫定findings

再検証前なので、まだ修復計画の確定根拠にはしない。

| ID | 暫定観察 | 主な確認対象 |
|---|---|---|
| ER-001 | Budget CLIがusageどおりの引数列に一致しない可能性 | `editor-app/Main.hs`、CLI-level test |
| ER-002 | 共通writerのpost-admissionがActual parserへ固定されている可能性 | CLI routing、`ActualWriter`、commit integration test |
| ER-003 | optionalなIssue amountをTSV admissionが受け取れない可能性 | Issue domain、renderer、TSV parser |
| ER-004 | Account rendererとJournal parserの間でidentityが変化し得る可能性 | `mkAccount`、account header parser、Account append |
| ER-005 | Planの日付欠落が固定日付へfallbackし、入力不正がpartial failureになる可能性 | CLI option parsing、Plan lifecycle |
| ER-006 | reversal自身のidentityと`reverses` provenanceのtyped retentionが不明確 | E4、Actual metadata admission、設計文書 |
| ER-007 | E7 TUIの負数Amount処理とstate transitionに未検証箇所がある可能性 | PR #14 `buildIntent`、TUI test |
| ER-008 | module testはあるがargvからcommitまでのexecutable-level coverageが不足する可能性 | Cabal test一覧、Editor tests |

## 4. 再レビュー方法

各項目について次を記録する。

1. exact source pathと該当境界
2. 最小の再現条件
3. 既存testが検出できない理由
4. 判定と重大度
5. 他findingとの依存

重大度:

- P0: source lossまたはsilent corruptionの危険
- P1: advertised commandが実行不能、または誤ったadmissionでpublishされる
- P2: valid domain stateを扱えない、process crash、identity/provenance欠落
- P3: coverage、diagnostic、presentation、documentationの不足

## 5. 次工程

- [ ] 各findingを再検証する
- [ ] 判定、重大度、最小再現、test gapを追記する
- [ ] finding間の依存を整理する
- [ ] coherent finite slice単位の順序付きTODOを追加する
- [ ] PR #14の扱いを決める
