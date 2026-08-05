# h-kernel Editor correctness review

ステータス: 再レビュー済み・T08検証完了  
Owner: h-kernel editor review  
Canonical: yes  
基準日: 2026-08-05  
基準main: `0a87f9e26fad038e28e3e371c2eafa7e1975f11b`

## 1. 役割

E4からE7までのEditorを、build成功だけでなく、CLI invocation、typed intent、candidate admission、write effect、post-admission、identity、test coverageの連続した境界として点検する。

この文書はcorrectness reviewと修復順序を所有する。実装のCURRENT/NEXTは引き続き`EDITOR_DEVELOPMENT_PLAN.md`が所有する。

## 2. Remote baseline

- main HEAD: `0a87f9e26fad038e28e3e371c2eafa7e1975f11b`
- E4、E5、E6はmainへmerge済み
- T01実装PR #16はmainへmerge済み
- T02実装PR #17はmainへmerge済み
- T03実装PR #18はmainへmerge済み
- T04実装PR #19はmainへmerge済み
- T05実装PR #20はmainへmerge済み
- T06実装PR #21はmainへmerge済み
- T07実装PR #22はmainへmerge済み
- open PR #14: `fix(editor): Actual add TUIの入力契約を回復する`
- #14は最新mainから再構成したT08 Ready PRで、全CI gate成功、merge待ち
- source mutation、他commandのTUI、writer authority、source migrationは含まない

## 3. 判定語彙

- `confirmed`: 一次レビューどおりの問題を確認した
- `corrected`: 問題はあるが、原因または影響範囲を修正した
- `open question`: 実装と文書の不一致は確認したが、正しいdomain contractの合意が必要

重大度:

- P0: silent source corruption、誤った意味の記録、復旧不能、またはprivate source内容の露出の危険
- P1: advertised commandが実行不能、または正しいsource ownerでpublishされない
- P2: valid domain stateを扱えない、process crash、identity/provenance欠落
- P3: coverage、diagnostic、presentation、documentationの不足

## 4. 再レビュー結果

| ID | 判定 | 重大度 | 結果 |
|---|---|---:|---|
| ER-001 | corrected | P1 | Budget commandはpure CLI admissionでusageどおりに解釈される |
| ER-002 | corrected | P1/P2 | source-specific post-admissionをsafe writerへ渡す |
| ER-003 | corrected | P2 | optional Issue amountと片側欠落をstable TSV admissionで区別する |
| ER-004 | corrected | P0 | Account declarationをcanonical render後にexact round-trip確認する |
| ER-005 | corrected | P0/P2 | Plan必須日付とgenerated identity失敗をtyped errorにする |
| ER-006 | corrected | P2 | reverse自身へ明示`event-id`を要求し、`reverses`をActual typed provenanceとして保持する |
| ER-007 | corrected | P2/P3 | TUI Amountをpositive magnitudeとしてpure admissionし、typed state transition testを持つ |
| ER-008 | corrected | P3 | pure CLI、commit integration、TUI contractの各層をfocused testする |
| ER-009 | corrected | P1 | `--commit`をleaf commandの先頭だけでadmitする |
| ER-010 | corrected | P0 | Plan finish amountをpositive magnitudeへ制限する |
| ER-011 | corrected | P2 | empty Issue sourceへの初回appendでstable headerを生成する |
| ER-012 | corrected | P0 | publish後read failureでもrestoreを試みる |
| ER-013 | corrected | P2 | Plan block renderingとPlan owner admissionを分離する |
| ER-014 | corrected | P0 | stale mismatch診断へactual source本文を保持しない |

## 5. Finding details

### ER-001 Budget argv mismatch

旧`editor-app/Main.hs`のBudget patternはcommodityの後に余分な引数を要求していた。pure CLI admissionへ分離し、usage shape、余分な引数、command-local `--commit`をfocused testで固定した。

### ER-002 source-specific post-admission

Actual、Plan、Budget、Issueのcandidateは、それぞれのstable ownerをsafe writerのpost-admissionとして渡す。temporary sourceを使うcommit evidenceで、publish、post-admission、rollbackの連続した境界を確認する。

### ER-003 optional Issue amount

Issue amountはquantityとcommodityの両方blankを`Nothing`としてadmitし、片側だけの欠落はtyped errorとして拒否する。rendererとstable TSV parserが同じoptional contractを共有する。

### ER-004 Account identity round-trip

Account Journal ownerがcanonical declaration rendererを持ち、追加対象のdeclarationがcandidate parse-back後もexact equalityを保つことを確認する。`;`を含みsource上で別identityへ変わる名前はpublish前に拒否する。

### ER-005 Plan date and generated identity

Plan add、finishの必須日付はflagの存在をtyped admissionで確認する。generated Plan IDの失敗をpartial `error`へ変換せず、invalid seriesを含めてtyped errorとして返す。

### ER-006 reverse identity/provenance

reverse transactionは元transactionを変更する操作ではなく、符号を反転したpostingsを持つ新しいActual transactionである。このためreverse自身にもexternally durableなidentityを要求し、CLIなどのadapterが明示`event-id`をtyped intentへ渡す。

`reverses`は表示専用commentではなくActual Journal metadata projectionが所有するtyped provenanceとする。parse-back後は、reverse自身の`event-id`とtargetのActual transaction identityを`ActualReversalDeclaration`として保持する。

規則は次のとおりとする。

- reverse自身の`event-id`は必須で、user/application adapterが明示する
- targetはadmitted Actual transaction identityで参照する
- unknown target、self reference、既存identityの再利用を拒否する
- 同じtargetへの直接reverseは一度だけ許可する
- reverse transaction自身をtargetにするreverse-of-reverseは、新しいidentityで許可する
- candidate complete sourceをActual ownerへ戻し、typed provenanceが保持されることを確認する
- diagnosticsへprivate source本文を含めない

### ER-007 E7 TUI input contract

TUIはAmountを`<positive quantity> <commodity>`というsurfaceとしてadmitする。negativeとzeroは`ActualAddAmountMustBePositive`として拒否し、balancing source postingは入力Textへ`-`を連結せず、admitted `Quantity`へ`negateQuantity`を適用して作る。

入力から`ActualEditIntent`を作る境界と、Account選択、cancel、preview、returnの状態遷移をBrick event loopの外へ出す。focused testはpositive、negative、zero、invalid shape、Account選択、preview block、private complete-source非保持を固定する。

### ER-008 executable coverage

coverageを次の四層に分ける。

1. pure domain/editor preview test
2. pure CLI argument admission test
3. temporary sourceを使うcommit integration test
4. TUI input/state transition test

### ER-009 command-local commit flag

commit指定は各leaf commandの先頭位置だけで一度admitする。description、memo、detailsなどに現れる`--commit`はuser-authored valueとして保持する。

### ER-010 Plan finish amount direction

`--actual-amount`はpositive magnitudeとしてadmitする。negativeとzeroをtyped errorへし、posting directionを入力符号で反転させない。

### ER-011 empty Issue source

blankまたはcomment-only sourceはempty Issue collectionとしてadmitする。初回appendはstable headerとrowを生成し、そのcomplete candidateをIssue ownerへ戻す。

### ER-012 post-publish IOException

writerはtarget publish後のreadまたはpost-admissionが失敗した場合もbackup restoreを試み、sourceが変更済みのままfailureだけを返さない。

### ER-013 Plan source ownership

source-neutralなvalidated transaction block rendererをActual appendから分ける。Plan addはPlan JournalのAccount registryでpostingを検証し、complete candidateをPlan ownerへ戻す。

### ER-014 stale source content exposure

stale判定は内容不一致という事実だけをtyped errorへ保持する。actual source bytesをerrorや`Show`結果へ含めず、private canonical source本文をterminalやlogへ出さない。

## 6. Ordered TODO

一つのPRで複数段階を混ぜない。

- [x] **T00: E7を保留状態へ戻す**  
  PR #14をDraftへ戻し、correctness recovery完了までmergeしない。

- [x] **T01: safe writer contract recovery**  
  source-specific post-admission、Actual・Plan・Budget・Issueのtemporary-file commit evidence、publish後IOExceptionのrestore、content-hidden stale診断をPR #16で固定し、mainへmergeした。対象: ER-002、ER-012、ER-014。

- [x] **T02: pure CLI admission boundary**  
  argv parsingをIO処理から分離し、Budget pattern、command-local `--commit`、Plan必須日付、Issue amount pairをtyped admissionで固定した。command-surface contract testを追加し、PR #17でmainへmergeした。対象: ER-001、ER-003のCLI部分、ER-005の日付、ER-008、ER-009。

- [x] **T03: Plan amount and identity safety**  
  finish amountをpositive magnitudeとしてadmitし、generated Plan ID失敗をtyped errorへした。negative、zero、invalid seriesをfocused testへ追加し、PR #18でmainへmergeした。対象: ER-005のpartial failure、ER-010。

- [x] **T04: Account declaration exact round-trip**  
  Account Journal ownerへcanonical rendererとprivacy-preserving typed errorを置き、全AccountTypeのrender/parse-back exact parityを検証した。`;`を含むunrepresentable identityはsource公開前にrejectし、complete candidate registryでも追加対象declarationのexact equalityを再確認し、PR #19でmainへmergeした。対象: ER-004。

- [x] **T05: Issue source contract alignment**  
  amount・currencyの両方blankを`Nothing`としてstable TSV admissionし、片側blankはtyped errorとしてrejectする。blank・comment-only sourceへの初回appendではstable headerを生成し、parser、Editor preview、temporary-file commitをPR #20で固定してmainへmergeした。対象: ER-003、ER-011。

- [x] **T06: Plan rendering/admission ownership**  
  source-neutralなvalidated transaction block境界をActual appendから分離し、Plan addはPlan JournalのAccount registryでpostingを検証・描画する。Plan sourceをActual admissionへ流さず、PlanとしてvalidかつActualとしてinvalidなmetadata sourceのfocused evidenceをPR #21で固定し、mainへmergeした。対象: ER-013とER-002のPlan部分。

- [x] **T07: reversal identity/provenance decision**  
  reverse自身の明示`event-id`、Actual ownerによるtyped `reverses` retention、unknown/self/duplicate rejection、direct reverse一回、reverse-of-reverse許可をPR #22で固定し、mainへmergeした。対象: ER-006。

- [ ] **T08: E7 TUI recovery**  
  PR #14を最新mainから再構成し、pure input constructor、positive amount contract、state transition test、`tests/fixtures/editor/`へのfixture placementを実装した。3つのGHCでbuild/test成功、GHC 9.10.3のrepository auditとcomplete Report contracts成功、Ready化済み、merge待ち。対象: ER-007。

- [ ] **T09: final verification and current-state docs**  
  GHC 9.10.3、9.12.4、9.14.1でbuild/test、repository audit、complete Report contractsを確認し、`EDITOR_DEVELOPMENT_PLAN.md`のCURRENT/NEXTを実能力に合わせる。

## 7. 進行規則

- TODOは上から一つずつ扱う。
- 各実装sliceは最新mainからDraft PRを作る。
- correctness、ownership、UI、source migration、writer cutoverを混ぜない。
- focused evidenceとfull CIを確認してからReady化する。
- mergeは作者の明示許可を待つ。
- private canonical sourceやwriter authorityを暗黙に変更しない。
