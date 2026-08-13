{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Household.Issue.Relation.TSV
import HKernel.Household.Issue.TSV
import HKernel.HouseholdIssue
import HKernel.Money
import HKernel.Plan (PlanId, mkPlanId, planIdText)
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , mkActualTransactionId
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeAcceptedIssues
  characterizeCompatibility
  characterizeSourceFailures
  characterizeIssueRelations
  characterizeIssueRelationReferences

characterizeAcceptedIssues :: IO ()
characterizeAcceptedIssues = do
  let issues = mustRight (parseHouseholdIssues validIssues)
      knownDueIssue = exactlyOne
        (filter ((== "issue-one") . issueIdText . householdIssueId) issues)
      noDueIssue = exactlyOne
        (filter ((== "issue-no-due") . issueIdText . householdIssueId) issues)
      closedIssue = exactlyOne
        (filter ((== "issue-closed") . issueIdText . householdIssueId) issues)
      issueWithoutAmount = exactlyOne
        (mustRight (parseHouseholdIssues optionalAmountIssue))
      jpy = mustRight (mkCommodity "JPY")

  assertEqual "one physical row becomes one typed HouseholdIssue"
    3
    (length issues)
  assertEqual "recorded date remains independent from due and closed"
    (fromGregorian 2026 7 20)
    (householdIssueRecordedOn knownDueIssue)
  assertEqual "known due is admitted from the due coordinate"
    (DueOn (fromGregorian 2026 8 15))
    (householdIssueDue knownDueIssue)
  assertEqual "open Issue has explicit not-closed meaning"
    NotClosed
    (householdIssueClosed knownDueIssue)
  assertEqual "explicit no-due remains typed"
    NoDueDate
    (householdIssueDue noDueIssue)
  assertEqual "closed date is independent from due"
    (ClosedOn (fromGregorian 2026 8 8))
    (householdIssueClosed closedIssue)
  assertEqual "amount and Commodity remain exact"
    (Just (mkAmount jpy (quantityFromInteger 200)))
    (householdIssueAmount knownDueIssue)
  assertEqual "category remains explicit context in details"
    "[planning] decide funding"
    (householdIssueDetails knownDueIssue)
  assertEqual "blank amount and currency retain no invented Amount"
    Nothing
    (householdIssueAmount issueWithoutAmount)
  assertEqual "blank and comment-only input admits no issues"
    []
    (mustRight (parseHouseholdIssues "\n# no current matters\n"))

characterizeCompatibility :: IO ()
characterizeCompatibility = do
  let dueAwareOpen = exactlyOne (mustRight (parseHouseholdIssues dueAwareOpenSource))
      dueAwareClosed = exactlyOne (mustRight (parseHouseholdIssues dueAwareClosedSource))
      legacyClosed = exactlyOne (mustRight (parseHouseholdIssues legacyClosedSource))
  assertEqual "current source owns both due and closed columns"
    True
    (householdIssueSourceUsesDueColumn validIssues
      && householdIssueSourceUsesClosedColumn validIssues)
  assertEqual "nine-column source retains due but not closed coordinate"
    True
    (householdIssueSourceUsesDueColumn dueAwareOpenSource
      && not (householdIssueSourceUsesClosedColumn dueAwareOpenSource))
  assertEqual "nine-column open Issue is known not closed"
    NotClosed
    (householdIssueClosed dueAwareOpen)
  assertEqual "nine-column historical closed Issue keeps missing closure evidence"
    ClosedUndetermined
    (householdIssueClosed dueAwareClosed)
  assertEqual "legacy source owns neither due nor closed coordinate"
    True
    (not (householdIssueSourceUsesDueColumn legacyClosedSource)
      && not (householdIssueSourceUsesClosedColumn legacyClosedSource))
  assertEqual "legacy missing due evidence becomes undetermined"
    DueUndetermined
    (householdIssueDue legacyClosed)
  assertEqual "legacy historical closed Issue keeps closure undetermined"
    ClosedUndetermined
    (householdIssueClosed legacyClosed)

characterizeSourceFailures :: IO ()
characterizeSourceFailures = do
  assertLeftAt "header is exact and retains its physical line"
    2
    "unexpected issues header"
    (parseHouseholdIssues (T.replace "issue_id" "id" validIssues))
  assertLeftAt "status vocabulary is closed"
    2
    "unknown issue status"
    (parseHouseholdIssues (T.replace "\topen\t" "\tpending\t" oneIssue))
  assertLeftAt "recorded date retains its physical line coordinate"
    2
    "invalid date"
    (parseHouseholdIssues (T.replace "2026-07-20" "2026-02-30" oneIssue))
  assertLeftAt "invalid explicit due fails closed"
    2
    "invalid issue due"
    (parseHouseholdIssues (T.replace "2026-08-15" "2026-02-30" oneIssue))
  assertLeftAt "invalid explicit closed date fails closed"
    2
    "invalid issue closed date"
    (parseHouseholdIssues (T.replace "\tnone\tplanning\t" "\t2026-02-30\tplanning\t" oneIssue))
  assertLeftAtMessageContains "open status cannot carry closure evidence"
    2
    "OpenHouseholdIssueHasClosureEvidence"
    (parseHouseholdIssues (T.replace "\tnone\tplanning\t" "\t2026-08-08\tplanning\t" oneIssue))
  assertLeftAtMessageContains "closed date cannot precede recorded date"
    2
    "HouseholdIssueClosedBeforeRecorded"
    (parseHouseholdIssues closedBeforeRecorded)
  assertLeftAt "current row width remains exact"
    2
    "expected ten issue columns"
    (parseHouseholdIssues (header <> "\nissue-one\topen\n"))
  assertLeftAt "nine-column row width remains exact"
    2
    "expected nine due-aware issue columns"
    (parseHouseholdIssues (dueAwareHeader <> "\nissue-one\topen\n"))
  assertLeftAt "legacy row width remains exact"
    2
    "expected eight legacy issue columns"
    (parseHouseholdIssues (legacyHeader <> "\nissue-one\topen\n"))
  assertLeftAt "blank amount cannot discard a present currency"
    2
    "amount and currency must both be blank or both be present"
    (parseHouseholdIssues amountBlankOnly)
  assertLeftAt "blank currency cannot discard a present amount"
    2
    "amount and currency must both be blank or both be present"
    (parseHouseholdIssues currencyBlankOnly)
  assertLeftAt "IssueId is unique across the admitted collection"
    0
    "duplicate identity"
    (parseHouseholdIssues duplicateIssues)

characterizeIssueRelations :: IO ()
characterizeIssueRelations = do
  let relations = mustRight (parseIssueRelations relationSource)
      firstRelation = head relations
      wrong = exactlyOne (mustRight (parseIssueRelations wrongRelationSource))
      fixed = exactlyOne (mustRight (parseIssueRelations fixedRelationSource))

  assertEqual "relation owner admits one row per historical occurrence"
    5
    (length relations)
  assertEqual "relation owner retains durable event identity"
    "rel-001"
    (issueRelationEventIdText (issueRelationEventId firstRelation))
  assertEqual "relation owner retains its own recorded date"
    (fromGregorian 2026 8 13)
    (issueRelationRecordedOn firstRelation)
  assertEqual "relation kind determines the typed Plan target"
    "plan-old"
    (case issueRelationMeaning firstRelation of
      IssueConcernsPlan planId -> planIdText planId
      other -> error ("expected concerns-plan, got " ++ show other))
  assertEqual "all five relation meanings survive source admission"
    [ "concerns-plan"
    , "planning-withdrawn"
    , "planned-as"
    , "funded-by"
    , "realized-as"
    ]
    (map relationKind relations)
  assertEqual "relation render/admit round-trip preserves typed history"
    relations
    (mustRight (parseIssueRelations (renderIssueRelations relations)))
  assertEqual "blank/comment-only relation input invents no history"
    []
    (mustRight (parseIssueRelations "\n# no relation history yet\n"))
  assertEqual "empty relation rendering emits a ready header"
    (issueRelationHeader <> "\n")
    (renderIssueRelations [])
  assertEqual "mistaken-target correction preserves relation event identity"
    (issueRelationEventId wrong)
    (issueRelationEventId fixed)
  assertEqual "mistaken-target correction can replace the typed Actual target"
    ("actual-wrong", "actual-right")
    (actualTarget wrong, actualTarget fixed)

  assertRelationLeftAt "relation header is exact"
    1
    "unexpected issue relation header"
    (parseIssueRelations (T.replace "relation_event_id" "id" oneRelationSource))
  assertRelationLeftAt "relation row width is exact"
    2
    "expected six issue relation columns"
    (parseIssueRelations (issueRelationHeader <> "\nrel-001\t2026-08-13\tissue-001\n"))
  assertRelationLeftAt "relation recorded_on is strict Gregorian text"
    3
    "invalid issue relation recorded-on"
    (parseIssueRelations invalidRelationDaySource)
  assertRelationLeftAt "relation vocabulary is closed"
    2
    "unknown issue relation kind"
    (parseIssueRelations (T.replace "concerns-plan" "linked-to" oneRelationSource))
  assertRelationLeftAt "relation event identity is unique"
    0
    "duplicate issue relation event identity"
    (parseIssueRelations duplicateRelationSource)

-- Reference integrity is characterized here before it receives a production
-- Household owner. Inputs are already-admitted identities, never raw roots.
-- In particular, the Actual collection means source-durable event identities,
-- not runtime reconstruction or physical source fallback identities.
characterizeIssueRelationReferences :: IO ()
characterizeIssueRelationReferences = do
  let relations = mustRight (parseIssueRelations relationSource)
      issue = mustRight (mkIssueId "issue-001")
      missingIssue = mustRight (mkIssueId "issue-missing")
      oldPlan = mustRight (mkPlanId "plan-old")
      newPlan = mustRight (mkPlanId "plan-new")
      missingPlan = mustRight (mkPlanId "plan-missing")
      transfer = mustRight (mkActualTransactionId "actual-transfer")
      payment = mustRight (mkActualTransactionId "actual-payment")
      runtimeActual = mustRight (mkActualTransactionId "plan-completion-plan-old")
      knownIssues = [issue]
      knownPlans = [oldPlan, newPlan]
      durableActuals = [transfer, payment]
      unknownIssueRelation = exactlyOne
        (mustRight (parseIssueRelations
          (T.replace "issue-001" "issue-missing" oneRelationSource)))
      unknownPlanRelation = exactlyOne
        (mustRight (parseIssueRelations
          (T.replace "plan-old" "plan-missing" oneRelationSource)))
      runtimeActualRelation = exactlyOne
        (mustRight (parseIssueRelations runtimeActualRelationSource))
      withdrawnRelation = exactlyOne
        (filter ((== "planning-withdrawn") . relationKind) relations)
      historicalPlanRelation = head relations

  assertEqual "reference admission accepts known Issue/Plan/durable Actual identities"
    (Right relations)
    (admitIssueRelationReferences knownIssues knownPlans durableActuals relations)
  assertEqual "reference admission rejects an unknown Issue identity"
    (Left (NonEmpty.fromList
      [UnknownIssueRelationIssue (issueRelationEventId unknownIssueRelation) missingIssue]))
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [unknownIssueRelation])
  assertEqual "reference admission rejects an unknown Plan identity"
    (Left (NonEmpty.fromList
      [UnknownIssueRelationPlanTarget (issueRelationEventId unknownPlanRelation) missingPlan]))
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [unknownPlanRelation])
  assertEqual "reference admission rejects a non-durable Actual runtime identity"
    (Left (NonEmpty.fromList
      [UnknownIssueRelationActualTarget (issueRelationEventId runtimeActualRelation) runtimeActual]))
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [runtimeActualRelation])
  assertEqual "historical Plan identity remains referable without an active-Plan filter"
    (Right [historicalPlanRelation])
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [historicalPlanRelation])
  assertEqual "planning-withdrawn requires Plan existence but no retirement state"
    (Right [withdrawnRelation])
    (admitIssueRelationReferences knownIssues knownPlans durableActuals [withdrawnRelation])

data IssueRelationReferenceError
  = UnknownIssueRelationIssue IssueRelationEventId IssueId
  | UnknownIssueRelationPlanTarget IssueRelationEventId PlanId
  | UnknownIssueRelationActualTarget IssueRelationEventId ActualTransactionId
  deriving (Eq, Show)

admitIssueRelationReferences
  :: [IssueId]
  -> [PlanId]
  -> [ActualTransactionId]
  -> [IssueRelationEvent]
  -> Either (NonEmpty.NonEmpty IssueRelationReferenceError) [IssueRelationEvent]
admitIssueRelationReferences knownIssues knownPlans durableActuals relations =
  case NonEmpty.nonEmpty (concatMap referenceErrors relations) of
    Nothing -> Right relations
    Just errors -> Left errors
  where
    referenceErrors relation = issueErrors relation ++ targetErrors relation
    issueErrors relation =
      [ UnknownIssueRelationIssue
          (issueRelationEventId relation)
          (issueRelationIssueId relation)
      | issueRelationIssueId relation `notElem` knownIssues
      ]
    targetErrors relation = case issueRelationMeaning relation of
      IssueConcernsPlan planId -> planErrors relation planId
      IssuePlannedAs planId -> planErrors relation planId
      IssuePlanningWithdrawn planId -> planErrors relation planId
      IssueRealizedAs actualId -> actualErrors relation actualId
      IssueFundedBy actualId -> actualErrors relation actualId
    planErrors relation planId =
      [ UnknownIssueRelationPlanTarget (issueRelationEventId relation) planId
      | planId `notElem` knownPlans
      ]
    actualErrors relation actualId =
      [ UnknownIssueRelationActualTarget (issueRelationEventId relation) actualId
      | actualId `notElem` durableActuals
      ]

relationKind :: IssueRelationEvent -> T.Text
relationKind relation = case issueRelationMeaning relation of
  IssueConcernsPlan _ -> "concerns-plan"
  IssuePlannedAs _ -> "planned-as"
  IssuePlanningWithdrawn _ -> "planning-withdrawn"
  IssueRealizedAs _ -> "realized-as"
  IssueFundedBy _ -> "funded-by"

actualTarget :: IssueRelationEvent -> T.Text
actualTarget relation = case issueRelationMeaning relation of
  IssueRealizedAs actualId -> actualTransactionIdText actualId
  other -> error ("expected realized-as, got " ++ show other)

header :: T.Text
header = householdIssuesHeader

dueAwareHeader :: T.Text
dueAwareHeader = dueAwareHouseholdIssuesHeader

legacyHeader :: T.Text
legacyHeader = legacyHouseholdIssuesHeader

oneIssue :: T.Text
oneIssue = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\t2026-08-15\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

optionalAmountIssue :: T.Text
optionalAmountIssue = T.unlines
  [ header
  , "issue-unknown-cost\topen\t2026-07-22\tundetermined\tnone\thome\tboiler\t\t\tinspect first"
  ]

amountBlankOnly :: T.Text
amountBlankOnly = T.unlines
  [ header
  , "issue-amount-blank\topen\t2026-07-22\tnone\tnone\thome\tboiler\t\tJPY\tinspect first"
  ]

currencyBlankOnly :: T.Text
currencyBlankOnly = T.unlines
  [ header
  , "issue-currency-blank\topen\t2026-07-22\tnone\tnone\thome\tboiler\t200\t\tinspect first"
  ]

validIssues :: T.Text
validIssues = T.unlines
  [ "# household notebook"
  , header
  , "issue-one\topen\t2026-07-20\t2026-08-15\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-no-due\topen\t2026-07-01\tnone\tnone\twant\tbookshelf\t\t\tlook for a good one"
  , "issue-closed\tresolved\t2026-07-02\tundetermined\t2026-08-08\twaiting\trepair schedule\t\t\tprovider replied"
  ]

dueAwareOpenSource :: T.Text
dueAwareOpenSource = T.unlines
  [ dueAwareHeader
  , "due-open\topen\t2026-07-20\t2026-08-15\tplanning\twifi\t200\tJPY\tdecide funding"
  ]

dueAwareClosedSource :: T.Text
dueAwareClosedSource = T.unlines
  [ dueAwareHeader
  , "due-closed\tresolved\t2026-07-20\tundetermined\tplanning\twifi\t200\tJPY\tdone"
  ]

legacyClosedSource :: T.Text
legacyClosedSource = T.unlines
  [ legacyHeader
  , "legacy-closed\tdropped\t2026-07-20\tplanning\twifi\t200\tJPY\tstopped"
  ]

closedBeforeRecorded :: T.Text
closedBeforeRecorded = T.unlines
  [ header
  , "issue-old\tresolved\t2026-08-10\tnone\t2026-08-09\tplanning\twifi\t200\tJPY\tdone"
  ]

duplicateIssues :: T.Text
duplicateIssues = T.unlines
  [ header
  , "issue-one\topen\t2026-07-20\tnone\tnone\tplanning\twifi\t200\tJPY\tdecide funding"
  , "issue-one\tresolved\t2026-07-21\tundetermined\tundetermined\tplanning\twifi\t0\tJPY\tdone"
  ]

relationSource :: T.Text
relationSource = T.unlines
  [ "# synthetic relation-source characterization"
  , issueRelationHeader
  , "rel-001\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\treview current commitment"
  , "rel-002\t2026-08-13\tissue-001\tplanning-withdrawn\tplan-old\tdecision changed"
  , "rel-003\t2026-08-13\tissue-001\tplanned-as\tplan-new\treplacement commitment"
  , "rel-004\t2026-08-13\tissue-001\tfunded-by\tactual-transfer\tmove funding first"
  , "rel-005\t2026-08-13\tissue-001\trealized-as\tactual-payment\tpayment occurred"
  ]

oneRelationSource :: T.Text
oneRelationSource = T.unlines
  [ issueRelationHeader
  , "rel-001\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\treview current commitment"
  ]

runtimeActualRelationSource :: T.Text
runtimeActualRelationSource = T.unlines
  [ issueRelationHeader
  , "rel-runtime\t2026-08-13\tissue-001\trealized-as\tplan-completion-plan-old\truntime identity is not durable source evidence"
  ]

wrongRelationSource :: T.Text
wrongRelationSource = T.unlines
  [ issueRelationHeader
  , "rel-correct\t2026-08-13\tissue-001\trealized-as\tactual-wrong\tmistaken target"
  ]

fixedRelationSource :: T.Text
fixedRelationSource = T.unlines
  [ issueRelationHeader
  , "rel-correct\t2026-08-13\tissue-001\trealized-as\tactual-right\tcorrected mistaken target"
  ]

duplicateRelationSource :: T.Text
duplicateRelationSource = T.unlines
  [ issueRelationHeader
  , "rel-dup\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\tfirst"
  , "rel-dup\t2026-08-14\tissue-001\tplanned-as\tplan-new\tsecond"
  ]

invalidRelationDaySource :: T.Text
invalidRelationDaySource = T.unlines
  [ "# comment preserves source line"
  , issueRelationHeader
  , "rel-001\t2026-02-30\tissue-001\tconcerns-plan\tplan-old\tbad day"
  ]

exactlyOne :: Show value => [value] -> value
exactlyOne [value] = value
exactlyOne values = error ("expected exactly one value, got " ++ show values)

assertLeftAt
  :: String
  -> Int
  -> T.Text
  -> Either (NonEmpty.NonEmpty HouseholdIssueTSVError) value
  -> IO ()
assertLeftAt label expectedLine expectedMessage result = case result of
  Left errors
    | any matches (NonEmpty.toList errors) ->
        putStrLn ("  [PASS] " ++ label)
    | otherwise -> failWith errors
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure
  where
    matches err =
      householdIssueTSVErrorLine err == expectedLine
        && householdIssueTSVErrorMessage err == expectedMessage
    failWith errors = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected line/message: "
        ++ show expectedLine ++ " / " ++ T.unpack expectedMessage)
      putStrLn ("    actual errors: " ++ show errors)
      exitFailure

assertLeftAtMessageContains
  :: String
  -> Int
  -> T.Text
  -> Either (NonEmpty.NonEmpty HouseholdIssueTSVError) value
  -> IO ()
assertLeftAtMessageContains label expectedLine fragment result = case result of
  Left errors
    | any matches (NonEmpty.toList errors) -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted source"
    exitFailure
  where
    matches err =
      householdIssueTSVErrorLine err == expectedLine
        && fragment `T.isInfixOf` householdIssueTSVErrorMessage err

assertRelationLeftAt
  :: String
  -> Int
  -> T.Text
  -> Either (NonEmpty.NonEmpty IssueRelationTSVError) value
  -> IO ()
assertRelationLeftAt label expectedLine expectedMessage result = case result of
  Left errors
    | any matches (NonEmpty.toList errors) -> putStrLn ("  [PASS] " ++ label)
    | otherwise -> do
        putStrLn ("  [FAIL] " ++ label)
        putStrLn ("    actual errors: " ++ show errors)
        exitFailure
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted relation source"
    exitFailure
  where
    matches err =
      issueRelationTSVErrorLine err == expectedLine
        && issueRelationTSVErrorMessage err == expectedMessage