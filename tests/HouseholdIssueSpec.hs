{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, assertEqual)
import Data.List (nub)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.HouseholdIssue
import HKernel.HouseholdIssue.Render
import HKernel.Editor.HouseholdWorkspace (issuesForWorkspace)
import HKernel.Money
import HKernel.Plan (mkPlanId, planIdText)
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , mkActualTransactionId
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeIssueIdentity
  characterizeHouseholdIssue
  characterizeIssueRelations
  characterizeIssueRelationSourceContract
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

-- Non-canonical characterization only. This deliberately lives in the test
-- boundary until h-kernel and bqn-ledger have demonstrated the same six source
-- coordinates. It does not add a ninth Household source or writer authority.
characterizeIssueRelationSourceContract :: IO ()
characterizeIssueRelationSourceContract = do
  let relations = mustRightText (parseIssueRelationPrototype relationSource)
      firstRelation = head relations
      corrected = exactlyOne
        (mustRightText (parseIssueRelationPrototype correctedRelationSource))

  assertEqual "relation source admits one row per historical relation occurrence"
    5
    (length relations)
  assertEqual "relation source retains durable event identity"
    "rel-001"
    (issueRelationEventIdText (issueRelationEventId firstRelation))
  assertEqual "relation source retains its own recorded date"
    (fromGregorian 2026 8 13)
    (issueRelationRecordedOn firstRelation)
  assertEqual "relation source retains Issue identity independently"
    "issue-001"
    (issueIdText (issueRelationIssueId firstRelation))
  assertEqual "relation kind determines the typed Plan target"
    "plan-old"
    (case issueRelationMeaning firstRelation of
      IssueConcernsPlan planId -> planIdText planId
      other -> error ("expected concerns-plan, got " ++ show other))
  assertEqual "relation details remain a separate coordinate"
    "review current commitment"
    (issueRelationDetails firstRelation)
  assertEqual "all five initial relation meanings survive source admission"
    [ "concerns-plan"
    , "planning-withdrawn"
    , "planned-as"
    , "funded-by"
    , "realized-as"
    ]
    (map (fst . renderRelationMeaning . issueRelationMeaning) relations)
  assertEqual "render then parse preserves the typed relation collection"
    relations
    (mustRightText (parseIssueRelationPrototype (renderIssueRelationPrototype relations)))
  assertEqual "blank and comment-only relation source admits no invented history"
    []
    (mustRightText (parseIssueRelationPrototype "\n# no relation history yet\n"))
  assertEqual "an explicit correction can retain event identity while fixing target"
    ("rel-correct", "actual-right")
    ( issueRelationEventIdText (issueRelationEventId corrected)
    , case issueRelationMeaning corrected of
        IssueRealizedAs actualId -> actualTransactionIdText actualId
        other -> error ("expected realized-as, got " ++ show other)
    )

  assertLeftText "relation header is exact"
    (parseIssueRelationPrototype (T.replace "relation_event_id" "id" relationSource))
  assertLeftText "relation row width is exact"
    (parseIssueRelationPrototype (relationHeader <> "\nrel-001\t2026-08-13\tissue-001\n"))
  assertLeftText "recorded-on must be a real explicit day"
    (parseIssueRelationPrototype
      (T.replace "2026-08-13" "2026-02-30" oneRelationSource))
  assertLeftText "relation vocabulary is closed"
    (parseIssueRelationPrototype
      (T.replace "concerns-plan" "linked-to" oneRelationSource))
  assertLeftText "Plan relation targets use PlanId admission"
    (parseIssueRelationPrototype
      (T.replace "plan-old" "plan old" oneRelationSource))
  assertLeftText "relation event identity is unique in the admitted collection"
    (parseIssueRelationPrototype duplicateRelationSource)
  assertLeftText "relation details retain domain hygiene"
    (parseIssueRelationPrototype detailsWithSurroundingWhitespace)

relationHeader :: T.Text
relationHeader = T.intercalate "\t"
  [ "relation_event_id"
  , "recorded_on"
  , "issue_id"
  , "relation_kind"
  , "target_id"
  , "details"
  ]

relationSource :: T.Text
relationSource = T.unlines
  [ "# synthetic relation-source characterization"
  , relationHeader
  , "rel-001\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\treview current commitment"
  , "rel-002\t2026-08-13\tissue-001\tplanning-withdrawn\tplan-old\tdecision changed"
  , "rel-003\t2026-08-13\tissue-001\tplanned-as\tplan-new\treplacement commitment"
  , "rel-004\t2026-08-13\tissue-001\tfunded-by\tactual-transfer\tmove funding first"
  , "rel-005\t2026-08-13\tissue-001\trealized-as\tactual-payment\tpayment occurred"
  ]

oneRelationSource :: T.Text
oneRelationSource = T.unlines
  [ relationHeader
  , "rel-001\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\treview current commitment"
  ]

correctedRelationSource :: T.Text
correctedRelationSource = T.unlines
  [ relationHeader
  , "rel-correct\t2026-08-13\tissue-001\trealized-as\tactual-right\tcorrected mistaken target"
  ]

duplicateRelationSource :: T.Text
duplicateRelationSource = T.unlines
  [ relationHeader
  , "rel-dup\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\tfirst"
  , "rel-dup\t2026-08-14\tissue-001\tplanned-as\tplan-new\tsecond"
  ]

detailsWithSurroundingWhitespace :: T.Text
detailsWithSurroundingWhitespace = T.unlines
  [ relationHeader
  , "rel-001\t2026-08-13\tissue-001\tconcerns-plan\tplan-old\t leading space"
  ]

parseIssueRelationPrototype :: T.Text -> Either T.Text [IssueRelationEvent]
parseIssueRelationPrototype input = case meaningfulRelationLines input of
  [] -> Right []
  (_, header) : rows
    | header /= relationHeader -> Left "unexpected issue relation header"
    | otherwise -> do
        relations <- traverse parseIssueRelationRow rows
        ensureUniqueRelationEventIds relations

parseIssueRelationRow :: (Int, T.Text) -> Either T.Text IssueRelationEvent
parseIssueRelationRow (lineNumber, line) = case T.splitOn "\t" line of
  [eventIdText, dayText, issueIdText', kind, targetText, details] -> do
    eventId <- atLine lineNumber (showLeft (mkIssueRelationEventId eventIdText))
    day <- atLine lineNumber (parseRelationDay dayText)
    issueId <- atLine lineNumber (showLeft (mkIssueId issueIdText'))
    meaning <- atLine lineNumber (parseRelationMeaning kind targetText)
    atLine lineNumber
      (showLeft (mkIssueRelationEvent eventId day issueId meaning details))
  _ -> Left (lineError lineNumber "expected six issue relation columns")

parseRelationMeaning :: T.Text -> T.Text -> Either T.Text IssueRelation
parseRelationMeaning kind target = case kind of
  "concerns-plan" -> IssueConcernsPlan <$> showLeft (mkPlanId target)
  "planned-as" -> IssuePlannedAs <$> showLeft (mkPlanId target)
  "planning-withdrawn" -> IssuePlanningWithdrawn <$> showLeft (mkPlanId target)
  "realized-as" -> IssueRealizedAs <$> showLeft (mkActualTransactionId target)
  "funded-by" -> IssueFundedBy <$> showLeft (mkActualTransactionId target)
  _ -> Left "unknown issue relation kind"

parseRelationDay :: T.Text -> Either T.Text Day
parseRelationDay value = case parseTimeM True defaultTimeLocale "%F" (T.unpack value) of
  Just day -> Right day
  Nothing -> Left "invalid issue relation recorded-on"

ensureUniqueRelationEventIds
  :: [IssueRelationEvent]
  -> Either T.Text [IssueRelationEvent]
ensureUniqueRelationEventIds relations
  | length identities == length (nub identities) = Right relations
  | otherwise = Left "duplicate issue relation event identity"
  where
    identities = map issueRelationEventId relations

renderIssueRelationPrototype :: [IssueRelationEvent] -> T.Text
renderIssueRelationPrototype relations = T.unlines
  (relationHeader : map renderIssueRelationRow relations)

renderIssueRelationRow :: IssueRelationEvent -> T.Text
renderIssueRelationRow relation = T.intercalate "\t"
  [ issueRelationEventIdText (issueRelationEventId relation)
  , T.pack (show (issueRelationRecordedOn relation))
  , issueIdText (issueRelationIssueId relation)
  , kind
  , target
  , issueRelationDetails relation
  ]
  where
    (kind, target) = renderRelationMeaning (issueRelationMeaning relation)

renderRelationMeaning :: IssueRelation -> (T.Text, T.Text)
renderRelationMeaning relation = case relation of
  IssueConcernsPlan planId -> ("concerns-plan", planIdText planId)
  IssuePlannedAs planId -> ("planned-as", planIdText planId)
  IssuePlanningWithdrawn planId -> ("planning-withdrawn", planIdText planId)
  IssueRealizedAs actualId -> ("realized-as", actualTransactionIdText actualId)
  IssueFundedBy actualId -> ("funded-by", actualTransactionIdText actualId)

meaningfulRelationLines :: T.Text -> [(Int, T.Text)]
meaningfulRelationLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

showLeft :: Show error => Either error value -> Either T.Text value
showLeft result = case result of
  Left err -> Left (T.pack (show err))
  Right value -> Right value

atLine :: Int -> Either T.Text value -> Either T.Text value
atLine lineNumber result = case result of
  Left err -> Left (lineError lineNumber err)
  Right value -> Right value

lineError :: Int -> T.Text -> T.Text
lineError lineNumber message =
  "line " <> T.pack (show lineNumber) <> ": " <> message

mustRightText :: Either T.Text value -> value
mustRightText result = case result of
  Left err -> error (T.unpack err)
  Right value -> value

assertLeftText :: String -> Either T.Text value -> IO ()
assertLeftText label result = case result of
  Left _ -> putStrLn ("  [PASS] " ++ label)
  Right _ -> do
    putStrLn ("  [FAIL] " ++ label)
    putStrLn "    unexpectedly accepted relation source"
    exitFailure

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
  assertEqual "workspace keeps open Issues first and newest-first within status groups"
    [ "open-new"
    , "open-old"
    , "resolved-newest"
    , "dropped-new"
    , "resolved-old"
    ]
    (map (issueIdText . householdIssueId) (issuesForWorkspace sourceIssues))
  assertEqual "workspace ordering does not mutate canonical source order"
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
