{-# LANGUAGE OverloadedStrings #-}

module HouseholdIssueSpec (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Time.Calendar (fromGregorian)
import HKernel.HouseholdIssue
import HKernel.HouseholdIssue.Render
import HKernel.Editor.HouseholdWorkspace
  ( IssueWorkspaceFilter(..)
  , issuesForWorkspace
  )
import HKernel.Money
import HKernel.Plan (mkPlanId)
import HKernel.Plan.Completion (mkActualTransactionId)
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeIssueIdentity
  characterizeHouseholdIssue
  characterizeIssueRelations
  characterizeIssueRelationReferences
  characterizeWorkspaceOrder
  characterizeCompleteLineRendering

characterizeIssueIdentity :: IO ()
characterizeIssueIdentity = do
  let issueId = mustRight (mkIssueId "issue-2026-001")

  assertEqual "issue identity retains its stable text"
    "issue-2026-001"
    (issueIdText issueId)
  assertLeft "empty issue identity is rejected"
    (mkIssueId "")
  assertLeft "issue identity with surrounding whitespace is rejected"
    (mkIssueId " issue-2026-001")
  assertLeft "issue identity with embedded whitespace is rejected"
    (mkIssueId "issue 2026 001")
  assertLeft "issue identity with a control character is rejected"
    (mkIssueId "issue\t2026")

characterizeHouseholdIssue :: IO ()
characterizeHouseholdIssue = do
  let issueId = mustRight (mkIssueId "issue-2026-001")
      recordedOn = fromGregorian 2026 8 1
      dueOn = fromGregorian 2026 8 8
      jpy = mustRight (mkCommodity "JPY")
      amount = mkAmount jpy (quantityFromInteger 4810)
      issue = mustRight (mkHouseholdIssue
        issueId
        recordedOn
        Open
        (DueOn dueOn)
        (Just amount)
        "Wi-Fi支払いをゆうちょで埋めるか"
        "節約中")

  assertEqual "issue retains its stable identity"
    issueId
    (householdIssueId issue)
  assertEqual "issue retains its recorded date"
    recordedOn
    (householdIssueRecordedOn issue)
  assertEqual "open and resolved remain distinct states"
    False
    (householdIssueStatus issue == Resolved)
  assertEqual "a known due date remains explicit"
    (DueOn dueOn)
    (householdIssueDue issue)
  assertEqual "an optional amount remains exact"
    (Just amount)
    (householdIssueAmount issue)
  assertEqual "issue text remains complete"
    "Wi-Fi支払いをゆうちょで埋めるか"
    (householdIssueText issue)
  assertEqual "issue details remain complete"
    "節約中"
    (householdIssueDetails issue)

  let noDue = mustRight (mkHouseholdIssue
        issueId
        recordedOn
        Open
        NoDueDate
        Nothing
        "いつか本棚を買い替える"
        "")
  assertEqual "explicit no-due remains distinct from unknown timing"
    NoDueDate
    (householdIssueDue noDue)

  let undetermined = mustRight (mkHouseholdIssue
        issueId
        recordedOn
        Resolved
        DueUndetermined
        Nothing
        "契約を続けるか確認する"
        "")
  assertEqual "due-undetermined is distinct from a known date"
    DueUndetermined
    (householdIssueDue undetermined)
  assertEqual "due-undetermined is distinct from explicit no-due"
    False
    (householdIssueDue undetermined == householdIssueDue noDue)
  assertEqual "non-monetary issues retain no amount"
    Nothing
    (householdIssueAmount undetermined)
  assertEqual "empty details are admitted without inventing content"
    ""
    (householdIssueDetails undetermined)

  assertLeft "empty issue text is rejected"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing "" "")
  assertLeft "issue text with surrounding whitespace is rejected"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      " 支払いを確認する" "")
  assertLeft "issue text cannot contain a hidden second line"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      "支払いを確認する\n来週" "")
  assertLeft "details with surrounding whitespace are rejected"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      "支払いを確認する" " 節約中")
  assertLeft "details cannot contain a hidden second line"
    (mkHouseholdIssue issueId recordedOn Open DueUndetermined Nothing
      "支払いを確認する" "節約中\n要相談")

characterizeIssueRelations :: IO ()
characterizeIssueRelations = do
  let issueId = mustRight (mkIssueId "issue-2026-001")
      eventId = mustRight (mkIssueRelationEventId "issue-rel-2026-001")
      day = fromGregorian 2026 8 6
      oldPlanId = mustRight (mkPlanId "plan-old")
      newPlanId = mustRight (mkPlanId "plan-new")
      actualId = mustRight (mkActualTransactionId "actual-transfer-001")
      concerns = mustRight (mkIssueRelationEvent
        eventId day issueId (IssueConcernsPlan oldPlanId) "reviewing current commitment")
      planned = mustRight (mkIssueRelationEvent
        (mustRight (mkIssueRelationEventId "issue-rel-2026-002"))
        day issueId (IssuePlannedAs newPlanId) "replacement commitment")
      withdrawn = mustRight (mkIssueRelationEvent
        (mustRight (mkIssueRelationEventId "issue-rel-2026-003"))
        day issueId (IssuePlanningWithdrawn oldPlanId) "intent changed")
      funded = mustRight (mkIssueRelationEvent
        (mustRight (mkIssueRelationEventId "issue-rel-2026-004"))
        day issueId (IssueFundedBy actualId) "asset transfer")
      realized = mustRight (mkIssueRelationEvent
        (mustRight (mkIssueRelationEventId "issue-rel-2026-005"))
        day issueId (IssueRealizedAs actualId) "actual purchase")

  assertEqual "relation event retains its durable identity"
    eventId
    (issueRelationEventId concerns)
  assertEqual "relation history retains its own recorded date"
    day
    (issueRelationRecordedOn concerns)
  assertEqual "relation remains anchored to the Issue identity"
    issueId
    (issueRelationIssueId concerns)
  assertEqual "an Issue can concern an existing Plan without claiming it created it"
    (IssueConcernsPlan oldPlanId)
    (issueRelationMeaning concerns)
  assertEqual "planned-as and planning-withdrawn are distinct historical facts"
    False
    (issueRelationMeaning planned == issueRelationMeaning withdrawn)
  assertEqual "funding an Issue and realizing it as Actual remain distinct meanings"
    False
    (issueRelationMeaning funded == issueRelationMeaning realized)
  assertEqual "relation details retain short household context"
    "asset transfer"
    (issueRelationDetails funded)

  assertLeft "relation event identity cannot be blank"
    (mkIssueRelationEventId "")
  assertLeft "relation event identity cannot contain whitespace"
    (mkIssueRelationEventId "issue relation")
  assertLeft "relation details reject surrounding whitespace"
    (mkIssueRelationEvent eventId day issueId (IssuePlannedAs newPlanId)
      " replacement commitment")
  assertLeft "relation details reject hidden control characters"
    (mkIssueRelationEvent eventId day issueId (IssuePlannedAs newPlanId)
      "replacement\tcommitment")

characterizeIssueRelationReferences :: IO ()
characterizeIssueRelationReferences = do
  let issue = mustRight (mkIssueId "issue-001")
      missingIssue = mustRight (mkIssueId "issue-missing")
      oldPlan = mustRight (mkPlanId "plan-old")
      newPlan = mustRight (mkPlanId "plan-new")
      missingPlan = mustRight (mkPlanId "plan-missing")
      transfer = mustRight (mkActualTransactionId "actual-transfer")
      payment = mustRight (mkActualTransactionId "actual-payment")
      runtimeActual = mustRight (mkActualTransactionId "plan-completion-plan-old")
      day = fromGregorian 2026 8 13
      relation eventId issueId meaning details = mustRight
        (mkIssueRelationEvent
          (mustRight (mkIssueRelationEventId eventId))
          day
          issueId
          meaning
          details)
      concerns = relation "rel-001" issue (IssueConcernsPlan oldPlan)
        "review current commitment"
      withdrawn = relation "rel-002" issue (IssuePlanningWithdrawn oldPlan)
        "decision changed"
      planned = relation "rel-003" issue (IssuePlannedAs newPlan)
        "replacement commitment"
      funded = relation "rel-004" issue (IssueFundedBy transfer)
        "move funding first"
      realized = relation "rel-005" issue (IssueRealizedAs payment)
        "payment occurred"
      relations = [concerns, withdrawn, planned, funded, realized]
      knownIssues = [issue]
      knownPlans = [oldPlan, newPlan]
      durableActuals = [transfer, payment]
      unknownIssueRelation = relation "rel-missing-issue" missingIssue
        (IssueConcernsPlan oldPlan) "dangling issue"
      unknownPlanRelation = relation "rel-missing-plan" issue
        (IssueConcernsPlan missingPlan) "dangling plan"
      runtimeActualRelation = relation "rel-runtime" issue
        (IssueRealizedAs runtimeActual) "runtime identity is not durable evidence"
      doublyDangling = relation "rel-double" missingIssue
        (IssuePlannedAs missingPlan) "both references are missing"

  assertEqual "reference admission accepts known Issue/Plan/durable Actual identities"
    (Right relations)
    (admitIssueRelationReferences knownIssues knownPlans durableActuals relations)
  assertEqual "reference admission rejects an unknown Issue identity"
    (Left (NonEmpty.fromList
      [UnknownIssueRelationIssue (issueRelationEventId unknownIssueRelation) missingIssue]))
    (admitIssueRelationReferences
      knownIssues knownPlans durableActuals [unknownIssueRelation])
  assertEqual "reference admission rejects an unknown Plan identity"
    (Left (NonEmpty.fromList
      [UnknownIssueRelationPlanTarget (issueRelationEventId unknownPlanRelation) missingPlan]))
    (admitIssueRelationReferences
      knownIssues knownPlans durableActuals [unknownPlanRelation])
  assertEqual "reference admission rejects a non-durable Actual runtime identity"
    (Left (NonEmpty.fromList
      [UnknownIssueRelationActualTarget
        (issueRelationEventId runtimeActualRelation)
        runtimeActual]))
    (admitIssueRelationReferences
      knownIssues knownPlans durableActuals [runtimeActualRelation])
  assertEqual "historical Plan identity remains referable without an active-Plan filter"
    (Right [concerns])
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [concerns])
  assertEqual "planning-withdrawn requires Plan existence but no retirement state"
    (Right [withdrawn])
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [withdrawn])
  assertEqual "reference admission accumulates both missing coordinates on one event"
    (Left (NonEmpty.fromList
      [ UnknownIssueRelationIssue (issueRelationEventId doublyDangling) missingIssue
      , UnknownIssueRelationPlanTarget (issueRelationEventId doublyDangling) missingPlan
      ]))
    (admitIssueRelationReferences
      knownIssues knownPlans durableActuals [doublyDangling])

characterizeWorkspaceOrder :: IO ()
characterizeWorkspaceOrder = do
  let issue status day issueId = mustRight (mkHouseholdIssue
        (mustRight (mkIssueId issueId))
        (fromGregorian 2026 8 day)
        status
        DueUndetermined
        Nothing
        issueId
        "")
      sourceIssues =
        [ issue Resolved 10 "resolved-newest"
        , issue Open 1 "open-old"
        , issue Dropped 9 "dropped-new"
        , issue Open 8 "open-new"
        , issue Resolved 2 "resolved-old"
        ]
  assertEqual "workspace defaults can project only open Issues newest-first"
    [ "open-new"
    , "open-old"
    ]
    (map (issueIdText . householdIssueId)
      (issuesForWorkspace OpenIssueFilter sourceIssues))
  assertEqual "workspace can explicitly project closed Issue history"
    [ "resolved-newest"
    , "dropped-new"
    , "resolved-old"
    ]
    (map (issueIdText . householdIssueId)
      (issuesForWorkspace ClosedIssueFilter sourceIssues))
  assertEqual "workspace can explicitly project all Issues with open attention first"
    [ "open-new"
    , "open-old"
    , "resolved-newest"
    , "dropped-new"
    , "resolved-old"
    ]
    (map (issueIdText . householdIssueId)
      (issuesForWorkspace AllIssueFilter sourceIssues))
  assertEqual "workspace filtering does not mutate canonical source order"
    [ "resolved-newest"
    , "open-old"
    , "dropped-new"
    , "open-new"
    , "resolved-old"
    ]
    (map (issueIdText . householdIssueId) sourceIssues)

characterizeCompleteLineRendering :: IO ()
characterizeCompleteLineRendering = do
  let issueId = mustRight (mkIssueId "issue-2026-001")
      jpy = mustRight (mkCommodity "JPY")
      issue = mustRight (mkHouseholdIssue
        issueId
        (fromGregorian 2026 8 1)
        Open
        (DueOn (fromGregorian 2026 8 8))
        (Just (mkAmount jpy (quantityFromInteger 4810)))
        "Wi-Fi支払いをゆうちょで埋めるか"
        "節約中")

  assertEqual "one-line rendering publishes every household-facing field"
    "2026-08-01 | open | due 2026-08-08 | 4810 JPY | Wi-Fi支払いをゆうちょで埋めるか | 節約中"
    (renderHouseholdIssueLine issue)

  let noDue = mustRight (mkHouseholdIssue
        issueId
        (fromGregorian 2026 8 2)
        Open
        NoDueDate
        Nothing
        "本棚を探す"
        "中古優先")
  assertEqual "explicit no-due remains visible"
    "2026-08-02 | open | no due date | no amount | 本棚を探す | 中古優先"
    (renderHouseholdIssueLine noDue)

  let noDateOrAmount = mustRight (mkHouseholdIssue
        issueId
        (fromGregorian 2026 8 2)
        Resolved
        DueUndetermined
        Nothing
        "契約を続けるか確認する"
        "確認済み")
  assertEqual "undetermined due date and absent amount remain visible"
    "2026-08-02 | resolved | due undetermined | no amount | 契約を続けるか確認する | 確認済み"
    (renderHouseholdIssueLine noDateOrAmount)

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right value -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn ("    unexpectedly accepted: " ++ show value)
    exitFailure
