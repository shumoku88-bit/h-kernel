# h-kernel Editor correctness review

ステータス: 再レビュー済み・T04検証完了  
Owner: h-kernel editor review  
Canonical: yes  
基準日: 2026-08-05  
基準main: `f6f36c77f36b61e8c45ed4900fcf35b67e5d0f75`

## 1. 役割

E4からE7までのEditorを、build成功だけでなく、CLI invocation、typed intent、candidate admission、write effect、post-admission、identity、test coverageの連続した境界として点検する。

この文書はcorrectness reviewと修復順序を所有する。実装のCURRENT/NEXTは引き続き`EDITOR_DEVELOPMENT_PLAN.md`が所有する。

## 2. Remote baseline

- main HEAD: `f6f36c77f36b61e8c45ed4900fcf35b67e5d0f75`
- E4、E5、E6はmainへmerge済み
- T01実装PR #16はmainへmerge済み
- T02実装PR #17はmainへmerge済み
- T03実装PR #18はmainへmerge済み
- open PR #14: `spike(editor): Brick Actual add preview TUIを追加する`
- #14 head: `f8d2cbadcbea6975bbbd13c990b2afeaa3637070`
- #14はE7完了ではなくActual add read-only preview spikeで、correctness recovery完了までDraft保留
- T04実装PR #19は全CI gate成功、merge待ち

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
| ER-001 | confirmed | P1 | Budget commandはusageどおりのargvではpatternに一致しない |
| ER-002 | corrected | P1/P2 | Budget・Issue commitはActual post-admissionでrollbackする。Planは必ず失敗するわけではないがownerが誤る |
| ER-003 | confirmed | P2 | optional Issue amountをrendererは表せるがTSV admissionが受け取れない |
| ER-004 | confirmed | P0 | Account名の`;`以後がcommentとして切られ、別identityをcommitし得る |
| ER-005 | confirmed | P0/P2 | Plan必須日付の欠落が2000-01-01になり、series由来ID失敗がpartial failureになる |
| ER-006 | open question | P2 | reverse transactionのidentityと`reverses` provenanceがtyped Actual evidenceにならない |
| ER-007 | confirmed | P2/P3 | E7 TUIの負数入力は`--100`を作り、pure input contract testがない |
| ER-008 | confirmed | P3 | executable argvからcommitまでのcontract testがない |
| ER-009 | confirmed | P1 | globalな`--commit`除去がdescription/detailsなどのuser dataも消す |
| ER-010 | confirmed | P0 | Plan finishへ負のamountを渡すとposting directionが反転する |
| ER-011 | confirmed | P2 | admitted empty Issue sourceへheaderを補わずappendするためcandidateが失敗する |
| ER-012 | confirmed | P0 | publish後のread IOExceptionではbackup restoreを試さずFileIOErrorだけを返す |
| ER-013 | confirmed | P2 | Plan addがPlan sourceを`prepareActualAppend`経由でActual admissionする |
| ER-014 | confirmed | P0 | stale mismatch errorが実際のsource全文を保持し、CLI診断へ露出し得る |

## 5. Finding details

### ER-001 Budget argv mismatch

`editor-app/Main.hs`のBudget patternはcommodityの後に`:_`を要求する。一方、`main`は先にすべての`--commit`を除去する。そのためusageに示された引数だけでは一致せず、無関係な余分の引数を付けた場合だけ起動する。

既存のBudget testは`prepareBudgetMovementAppend`だけを直接呼び、CLI parserを通らない。

### ER-002 source-specific post-admission

`executePreview`はすべてのsource kindを`publishActualAppend`へ渡す。writerはpublish後に常に`parseActualJournal`を使う。

- Actual append、reverse、Account appendはActual Journalなのでownerが一致する
- Budget TSVとIssue TSVはcandidate作成時には各stable parserを使うが、publish後にActual parserへ渡されるためrollbackする
- Plan add candidateは事前にPlan admissionされるため、通常形ではwriterが必ず失敗するとは限らない。ただしpost-admission ownerはPlanではない

一次レビューの「Planも必ずrollback」は撤回し、owner mismatchへ修正する。

### ER-003 optional Issue amount

`HouseholdIssue`と`IssueAppendIntent`は`Maybe Amount`を持ち、rendererは`Nothing`をamount/currencyの空欄として出力する。`parseHouseholdIssues`は空欄でも`parseQuantity`と`mkCommodity`を必須実行するため、candidate parseが失敗する。

CLIはqtyまたはcommodityの片方だけが`-`でもamount全体を`Nothing`にする。片方の入力を黙って捨てず、「両方`-`」または「両方明示」を要求する必要がある。

### ER-004 Account identity round-trip

`mkAccount`は`;`を許すが、Journal account headerは`;`以後をcommentとして除く。`ActualAccountAppend`は元のdeclarationとparse-back declarationのexact equalityを確認しない。

例として`expenses:food;legacy`を追加すると、candidate sourceにはそのTextが出るが、parse後は`expenses:food`として受理され得る。これはparse可能性ではなくidentity parityで拒否すべきである。

### ER-005 Plan date and generated identity

CLIはPlan addとfinishの初期値に`2000-01-01`を入れ、日付flagの存在を確認しない。missing dateはtyped errorにならず、利用者が指定していない日付でcandidateを生成する。

`generatePlanId`はseries textをslugifyせず、`mkPlanId`失敗を`error "invalid generated id"`へ変える。whitespaceを含むseriesなどでprocess crashになり得る。

### ER-006 reverse identity/provenance

reverse rendererは`; reverses: <event-id>`を出すが、Actual metadata admissionが意味を与えるkeyは`event-id`と`plan-id`だけである。`reverses`はtyped projectionに残らず、reverse transaction自身にもdurable `event-id`がない。

`EDITOR_DEVELOPMENT_PLAN.md`はreverseを「identity/provenanceを持つ新しいtransaction」と記述する。必要なidentity生成規則とprovenance ownerを先に合意する。

### ER-007 E7 TUI input contract

PR #14の`buildIntent`は入力Quantityをそのままdestinationへ使い、source側を文字列`"-" <> qty`で作る。`-100 JPY`はsource側で`--100`となる。

TUIをpositive magnitudeだけのsurfaceとする場合は、その制限をpure constructorで明示し、負数をtyped validation errorとして扱う。event loopへ埋めたままにせずfocused test可能な境界へ出す。

### ER-008 executable coverage

CabalにはEditor module単位のtest suiteがあるが、`editor-app/Main.hs`をargvから実行するcontract testがない。このためER-001、ER-002、ER-005、ER-009が`cabal test all`を通過した。

coverageを次の四層に分ける。

1. pure domain/editor preview test
2. pure CLI argument admission test
3. temporary sourceを使うcommit integration test
4. TUI input/state transition test

### ER-009 global commit flag removal

`cleanArgs = filter (/= "--commit") args`はflag位置を解釈せず、同じTextをdescriptionやdetailsとして記録したい場合も削除する。commit指定は各commandの構造内で一度だけadmitし、user-authored valueと混同しない。

### ER-010 Plan finish negative amount

binary Planの更新は、元postingの符号に応じて`newQty`または`negateQuantity newQty`を使う。`newQty`が負の場合、両postingの符号が逆転して支払方向が反転する。

`--actual-amount`はpositive magnitudeとしてadmitするか、signed replacementとして別の明示contractを定める必要がある。現在のCLI語彙ではpositive magnitudeが自然である。

### ER-011 empty Issue source

`parseHouseholdIssues`はblank/comment-only sourceをempty collectionとしてadmitする。一方、Issue rendererはrowだけをappendし、headerを生成しない。admitted empty sourceから作ったcandidateの先頭rowがheaderとして解釈され、拒否される。

### ER-012 post-publish IOException

writerはtarget rename後にsourceを再読込する。そのreadがIOExceptionになると、外側のcatchが`FileIOError`を返すだけでrollbackを試みない。sourceは変更済みなのに失敗だけが返る可能性があり、safe writer contractに反する。

### ER-013 Plan source admitted as Actual

`preparePlanAdd`は最初に`parsePlanJournal`するが、block生成のため`prepareActualAppend planSource actualIntent`を呼び、同じPlan sourceを再びActual Journalとしてadmitする。

Plan parserが無関係metadataとして許す`event-id`をActual parserは意味のあるidentityとして解釈する。したがってPlan ownerではvalidなsourceがEditor経路で拒否され得る。transaction rendererとsource-specific admissionを分ける必要がある。

### ER-014 stale source content exposure

writerの`StaleFile`は、比較に使った実際のsource全体を`staleActualBytes`としてerrorへ保持する。CLIはwrite errorを`show`しているため、private canonical sourceの全内容をterminalやlogへ出す可能性がある。

stale判定には内容の不一致だけが必要であり、actual bytesを診断へ含めない。内容非表示のtyped mismatchとして返し、testでも`Show`結果にsource内容が含まれないことを固定する。

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

- [ ] **T04: Account declaration exact round-trip**  
  Account Journal ownerへcanonical rendererとprivacy-preserving typed errorを置き、全AccountTypeのrender/parse-back exact parityを検証した。`;`を含むunrepresentable identityはsource公開前にrejectし、complete candidate registryでも追加対象declarationのexact equalityを再確認する。対象: ER-004。PR #19は全CI gate成功、merge待ち。

- [ ] **T05: Issue source contract alignment**  
  optional amountのblank pairをstable TSV admissionで表し、empty admitted sourceへの初回appendではheaderを生成する。parser、renderer、Editor testを同じsliceで揃える。対象: ER-003、ER-011。

- [ ] **T06: Plan rendering/admission ownership**  
  validated transactionのrenderingをActual source admissionから分離し、Plan addはPlan sourceだけをPlan ownerでadmitする。対象: ER-013とER-002のPlan部分。

- [ ] **T07: reversal identity/provenance decision**  
  reverse transaction自身のidentity、元transaction参照key、typed retention、duplicate ruleを合意してから実装する。対象: ER-006。

- [ ] **T08: E7 TUI recovery**  
  PR #14を修復後mainへrebaseし、pure input constructor、positive amount contract、state transition test、fixture placementを整える。対象: ER-007。

- [ ] **T09: final verification and current-state docs**  
  GHC 9.10.3、9.12.4、9.14.1でbuild/test、repository audit、complete Report contractsを確認し、`EDITOR_DEVELOPMENT_PLAN.md`のCURRENT/NEXTを実能力に合わせる。

## 7. 進行規則

- TODOは上から一つずつ扱う。
- 各実装sliceは最新mainからDraft PRを作る。
- correctness、ownership、UI、source migration、writer cutoverを混ぜない。
- focused evidenceとfull CIを確認してからReady化する。
- mergeは作者の明示許可を待つ。
- private canonical sourceやwriter authorityを暗黙に変更しない。
