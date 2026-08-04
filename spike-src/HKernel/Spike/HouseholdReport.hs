{-# LANGUAGE OverloadedStrings #-}

-- | Read-only observation adapter for the current household source set.
--
-- General Budget policy, Household policy, and Daily Target meaning are owned
-- by stable components. This module composes their typed values with retained
-- compatibility sources; it does not write, migrate, or generate any source.
module HKernel.Spike.HouseholdReport
  ( HouseholdSourceError(..)
  , HouseholdReportSurface(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeReconciliationDelta
  , DailyTarget(..)
  , dailyTargetCapacity
  , dailyTargetRate
  , buildHouseholdReportSurfaceFromPlanJournal
  ) where

import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Account
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
  , actualJournalValue
  )
import HKernel.Application.Config
  ( ApplicationConfigError
  , applicationConfigErrorLine
  , applicationConfigErrorMessage
  , parseApplicationConfig
  )
import HKernel.Budget.Config (parseBudgetPolicy)
import HKernel.Engine
  ( LedgerEntry(..)
  , journalEntries
  )
import HKernel.Household.Backing
  ( HouseholdBackingPlan(..)
  , EnvelopeBackingLine(..)
  , envelopeLedgerRemaining
  , envelopePostPlanHeadroom
  , EnvelopeBacking(..)
  , envelopeSignedTotal
  , envelopeBackingRequired
  , envelopeBackingSurplus
  , envelopeReconciliationDelta
  , deriveHouseholdBacking
  )
import HKernel.Household.BudgetMovement.TSV
import HKernel.Household.Config
  ( parseHouseholdPolicy
  )
import HKernel.Household.DailyTarget
import HKernel.Household.DailyTarget.TSV
import HKernel.Household.Issue.TSV
import HKernel.Household.Policy
  ( householdCycleIncomeAccount
  , householdPolicyCycle
  , validateHouseholdPolicyAccounts
  )
import HKernel.HouseholdIssue
import HKernel.Journal (Journal, journalAccountRegistry)
import HKernel.Ledger
  ( postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money
import HKernel.Period
import HKernel.Plan
import HKernel.Plan.Completion
  ( PlanCompletionDeclaration
  , declaredCompletionPlanId
  , resolveOpenCommittedOutgoingPlans
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , ProjectedCommittedOutgoingPlan
  , classifiedIncomingPlanTransactions
  , classifyPlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalValue
  , projectCommittedOutgoingPlans
  , projectedCommittedOutgoingPlan
  )
import HKernel.Report.CycleAccounts
import HKernel.Spike.HouseholdConsumption
  ( deriveHouseholdBudgetObservation
  , householdBudgetObservationPolicy
  , householdBudgetConsumption
  , householdBudgetEntitlement
  , householdBudgetRemaining
  )

-- | A source-local admission failure. Private source text is deliberately not
-- retained, so CLI diagnostics cannot accidentally echo a complete row.
data HouseholdSourceError = HouseholdSourceError
  { householdSourceName    :: Text
  , householdSourceLine    :: Int
  , householdSourceMessage :: Text
  } deriving (Eq, Show)

data AccountFact = AccountFact
  { accountFactAccount     :: Account
  , accountFactRole        :: AccountType
  , accountFactCurrency    :: Commodity
  , accountFactKind        :: Maybe Text
  , accountFactClass       :: Maybe Text
  , accountFactBudget      :: Maybe Text
  , accountFactBudgetGroup :: Maybe Text
  } deriving (Eq, Show)

-- | A future income movement used only as evidence for cycle resolution.
--
-- It is deliberately not represented by 'CommittedOutgoingPlan'.
data IncomingCycleAnchor = IncomingCycleAnchor
  { incomingAnchorId     :: PlanId
  , incomingAnchorDate   :: Day
  , incomingAnchorSource :: Account
  } deriving (Eq, Show)

data PlanFact = PlanFact
  { planFactValue :: CommittedOutgoingPlan
  , planFactFrom  :: Account
  , planFactTo    :: Account
  } deriving (Eq, Show)

data AdmittedPlans = AdmittedPlans
  { admittedIncomingAnchors :: [IncomingCycleAnchor]
  , admittedOutgoingPlans   :: [PlanFact]
  } deriving (Eq, Show)

data HouseholdReportSurface = HouseholdReportSurface
  { householdCycleAccounts       :: CycleAccounts
  , householdPlannedTransactions :: [CommittedOutgoingPlan]
  , householdIssues              :: [HouseholdIssue]
  , householdEnvelopeBacking     :: EnvelopeBacking
  , householdDailyTarget         :: DailyTarget
  } deriving (Eq, Show)

buildHouseholdReportSurfaceFromPlanJournal
  :: Day
  -> ActualJournal
  -> Text
  -> Text
  -> Text
  -> Text
  -> PlanJournal
  -> Text
  -> Text
  -> Text
  -> Either (NonEmpty HouseholdSourceError) HouseholdReportSurface
buildHouseholdReportSurfaceFromPlanJournal observation actualJournal accountsText budgetText budgetPolicyText householdPolicyText planJournal configText issuesText dailyScopeText = do
  accounts <- parseAccounts accountsText
  validateRegistry journal accounts
  _ <- mapLeft applicationConfigSourceErrors
    (parseApplicationConfig configText)
  budgetPolicy <- mapLeft budgetPolicySourceErrors
    (parseBudgetPolicy budgetPolicyText)
  policy <- mapLeft policySourceErrors
    (parseHouseholdPolicy budgetPolicy householdPolicyText)
  validatedPolicy <- mapLeft
    (fmap (sourceError "household.toml" 0 . tshow))
    (validateHouseholdPolicyAccounts (journalAccountRegistry journal) policy)
  validatePlanJournalRegistry journal planJournal
  admittedPlans <- admitPlanJournal planJournal
  let cycleAccount = householdCycleIncomeAccount (householdPolicyCycle policy)
  (current, previous) <- resolveCycles observation journal cycleAccount
    (admittedIncomingAnchors admittedPlans)
  budget <- mapLeft budgetMovementSourceErrors
    (parseHouseholdBudgetMovements budgetText)
  issues <- mapLeft issueSourceErrors (parseHouseholdIssues issuesText)
  let outgoingPlans = admittedOutgoingPlans admittedPlans
  outgoingDeclarations <- completionDeclarationsForOutgoingPlans admittedPlans
    (actualJournalCompletionDeclarations actualJournal)
  openPlanValues <- mapLeft
    (fmap (sourceError "actual.journal" 0 . tshow))
    (resolveOpenCommittedOutgoingPlans
      (map planFactValue outgoingPlans)
      (actualJournalIdentifiedTransactions actualJournal)
      outgoingDeclarations)
  dailyScope <- mapLeft dailyTargetSourceErrors
    (parseDailyTargetScope
      (journalAccountRegistry journal)
      (map planFactValue outgoingPlans)
      dailyScopeText)
  budgetObservation <- mapLeft
    (fmap (sourceError "budget_alloc.tsv" 0 . tshow))
    (deriveHouseholdBudgetObservation observation current journal
      validatedPolicy budget)
  let admittedPolicy = householdBudgetObservationPolicy budgetObservation
      consumption = householdBudgetConsumption budgetObservation
      entitlement = householdBudgetEntitlement budgetObservation
      remaining = householdBudgetRemaining budgetObservation
      openPlanIds = Set.fromList (map committedPlanId openPlanValues)
      openPlans = openPlansInPeriod current
        (journalAccountRegistry journal) openPlanIds outgoingPlans
      backingPlans =
        [ HouseholdBackingPlan
            { householdBackingPlanDestination = planFactTo plan
            , householdBackingPlanAmount = committedPlanAmount (planFactValue plan)
            }
        | plan <- openPlans
        ]
      backing = deriveHouseholdBacking
        observation current journal admittedPolicy
        budget entitlement consumption remaining backingPlans
      target = deriveDailyTarget observation current journal
        dailyScope (map planFactValue openPlans)
  pure HouseholdReportSurface
    { householdCycleAccounts = cycleAccounts current previous journal
    , householdPlannedTransactions = map planFactValue openPlans
    , householdIssues = issues
    , householdEnvelopeBacking = backing
    , householdDailyTarget = target
    }
  where
    journal = actualJournalValue actualJournal

validatePlanJournalRegistry
  :: Journal
  -> PlanJournal
  -> Either (NonEmpty HouseholdSourceError) ()
validatePlanJournalRegistry actual planJournal =
  case NonEmpty.nonEmpty errors of
    Nothing -> Right ()
    Just values -> Left values
  where
    actualRegistry = journalAccountRegistry actual
    planRegistry = journalAccountRegistry (planJournalValue planJournal)
    errors =
      [ sourceError "plan.journal" 0
          ("Account metadata disagrees with actual.journal for "
            <> accountName account)
      | declaration <- accountDeclarations planRegistry
      , let account = declaredAccount declaration
      , lookupAccountDeclaration account actualRegistry /= Just declaration
      ]

admitPlanJournal
  :: PlanJournal
  -> Either (NonEmpty HouseholdSourceError) AdmittedPlans
admitPlanJournal planJournal = do
  classified <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (classifyPlanJournal planJournal)
  incoming <- mapLeft NonEmpty.singleton
    (traverse
      (projectIncomingCycleAnchor registry)
      (classifiedIncomingPlanTransactions classified))
  projected <- mapLeft
    (fmap (sourceError "plan.journal" 0 . tshow))
    (projectCommittedOutgoingPlans planJournal classified)
  pure AdmittedPlans
    { admittedIncomingAnchors = incoming
    , admittedOutgoingPlans = map projectPlanFact projected
    }
  where
    registry = journalAccountRegistry (planJournalValue planJournal)

projectIncomingCycleAnchor
  :: AccountRegistry
  -> IdentifiedPlanTransaction
  -> Either HouseholdSourceError IncomingCycleAnchor
projectIncomingCycleAnchor registry identified =
  case Set.toAscList incomeSources of
    [source] -> Right IncomingCycleAnchor
      { incomingAnchorId = identifiedPlanId identified
      , incomingAnchorDate = transactionDate transaction
      , incomingAnchorSource = source
      }
    _ -> Left (sourceError "plan.journal" 0
      "incoming cycle anchor requires exactly one Income source Account")
  where
    transaction = identifiedPlanTransaction identified
    incomeSources = Set.fromList
      [ postingAccount posting
      | posting <- NonEmpty.toList (transactionPostings transaction)
      , accountTypeFor (postingAccount posting) registry == Just Income
      , amountQuantity (postingAmount posting) < zeroQuantity
      ]

projectPlanFact :: ProjectedCommittedOutgoingPlan -> PlanFact
projectPlanFact projected = PlanFact
  { planFactValue = plan
  , planFactFrom = declaredAccount (declaredPaymentSource direction)
  , planFactTo = declaredAccount (declaredPaymentDestination direction)
  }
  where
    plan = projectedCommittedOutgoingPlan projected
    direction =
      declaredOutgoingPaymentDirection (committedPlanDirection plan)

completionDeclarationsForOutgoingPlans
  :: AdmittedPlans
  -> [PlanCompletionDeclaration]
  -> Either (NonEmpty HouseholdSourceError) [PlanCompletionDeclaration]
completionDeclarationsForOutgoingPlans plans declarations =
  case NonEmpty.nonEmpty unknownErrors of
    Just errors -> Left errors
    Nothing -> Right
      [ declaration
      | declaration <- declarations
      , Set.member (declaredCompletionPlanId declaration) outgoingPlanIds
      ]
  where
    incomingPlanIds = Set.fromList
      (map incomingAnchorId (admittedIncomingAnchors plans))
    outgoingPlanIds = Set.fromList
      (map (committedPlanId . planFactValue) (admittedOutgoingPlans plans))
    knownPlanIds = Set.union incomingPlanIds outgoingPlanIds
    unknownErrors =
      [ sourceError "actual.journal" 0
          ("completion relation refers to unknown PlanId " <> planIdText planId)
      | declaration <- declarations
      , let planId = declaredCompletionPlanId declaration
      , Set.notMember planId knownPlanIds
      ]

sourceError :: Text -> Int -> Text -> HouseholdSourceError
sourceError = HouseholdSourceError

budgetPolicySourceErrors :: [Text] -> NonEmpty HouseholdSourceError
budgetPolicySourceErrors errors = case NonEmpty.nonEmpty mapped of
  Just values -> values
  Nothing -> sourceError "budget.toml" 0
    "unknown Budget policy admission failure" NonEmpty.:| []
  where
    mapped = map (sourceError "budget.toml" 0) errors

policySourceErrors :: [Text] -> NonEmpty HouseholdSourceError
policySourceErrors errors = case NonEmpty.nonEmpty mapped of
  Just values -> values
  Nothing -> sourceError "household.toml" 0
    "unknown Household policy admission failure" NonEmpty.:| []
  where
    mapped = map (sourceError "household.toml" 0) errors

applicationConfigSourceErrors
  :: NonEmpty ApplicationConfigError
  -> NonEmpty HouseholdSourceError
applicationConfigSourceErrors = fmap toSourceError
  where
    toSourceError err = sourceError
      "config.tsv"
      (applicationConfigErrorLine err)
      (applicationConfigErrorMessage err)

dailyTargetSourceErrors
  :: NonEmpty DailyTargetTSVError
  -> NonEmpty HouseholdSourceError
dailyTargetSourceErrors = fmap toSourceError
  where
    toSourceError err = sourceError
      "daily_target_scope.tsv"
      (dailyTargetTSVErrorLine err)
      (dailyTargetTSVErrorMessage err)

budgetMovementSourceErrors
  :: NonEmpty HouseholdBudgetMovementTSVError
  -> NonEmpty HouseholdSourceError
budgetMovementSourceErrors = fmap toSourceError
  where
    toSourceError err = sourceError
      "budget_alloc.tsv"
      (householdBudgetMovementTSVErrorLine err)
      (householdBudgetMovementTSVErrorMessage err)

issueSourceErrors
  :: NonEmpty HouseholdIssueTSVError
  -> NonEmpty HouseholdSourceError
issueSourceErrors = fmap toSourceError
  where
    toSourceError err = sourceError
      "issues.tsv"
      (householdIssueTSVErrorLine err)
      (householdIssueTSVErrorMessage err)

meaningfulLines :: Text -> [(Int, Text)]
meaningfulLines =
  filter (not . ignored . snd) . zip [1..] . T.lines
  where
    ignored line =
      let stripped = T.strip line
      in T.null stripped || "#" `T.isPrefixOf` stripped

parseAccounts
  :: Text
  -> Either (NonEmpty HouseholdSourceError) (Map Account AccountFact)
parseAccounts input = collectUnique "accounts.tsv" accountFactAccount
  =<< mapLeft NonEmpty.singleton
        (traverse parseAccountLine (meaningfulLines input))

parseAccountLine :: (Int, Text) -> Either HouseholdSourceError AccountFact
parseAccountLine (lineNumber, line) = case T.splitOn "\t" line of
  accountText : fields -> do
    account <- mapLeft (sourceError "accounts.tsv" lineNumber . tshow)
      (mkAccount accountText)
    metadata <- parseAccountMetadata lineNumber fields
    roleText <- requireField "accounts.tsv" lineNumber "role" metadata
    role <- parseRole lineNumber roleText
    currencyText <- requireField "accounts.tsv" lineNumber "currency" metadata
    currency <- mapLeft (sourceError "accounts.tsv" lineNumber . tshow)
      (mkCommodity currencyText)
    pure AccountFact
      { accountFactAccount = account
      , accountFactRole = role
      , accountFactCurrency = currency
      , accountFactKind = Map.lookup "kind" metadata
      , accountFactClass = Map.lookup "type" metadata
      , accountFactBudget = Map.lookup "budget" metadata
      , accountFactBudgetGroup = Map.lookup "budget_group" metadata
      }
  _ -> Left (sourceError "accounts.tsv" lineNumber "expected an account row")

parseAccountMetadata
  :: Int
  -> [Text]
  -> Either HouseholdSourceError (Map Text Text)
parseAccountMetadata lineNumber fields = do
  entries <- traverse parseField fields
  case duplicateKeys fst entries of
    [] -> Right (Map.fromList entries)
    duplicate : _ -> Left (sourceError "accounts.tsv" lineNumber
      ("duplicate metadata key " <> duplicate))
  where
    parseField field = case T.breakOn "=" field of
      (key, remainder)
        | not (T.null key)
        , not (T.null remainder)
        , let value = T.drop 1 remainder
        , not (T.null value) -> Right (key, value)
      _ -> Left (sourceError "accounts.tsv" lineNumber
        ("malformed metadata field " <> field
          <> "; expected non-empty key=value"))

parseRole :: Int -> Text -> Either HouseholdSourceError AccountType
parseRole lineNumber role = case T.toCaseFold role of
  "asset" -> Right Asset
  "liability" -> Right Liability
  "equity" -> Right Equity
  "income" -> Right Income
  "expense" -> Right Expense
  "budget" -> Right Budget
  _ -> Left (sourceError "accounts.tsv" lineNumber
    ("unsupported role " <> role))

validateRegistry
  :: Journal
  -> Map Account AccountFact
  -> Either (NonEmpty HouseholdSourceError) ()
validateRegistry journal accounts = case NonEmpty.nonEmpty errors of
  Nothing -> Right ()
  Just values -> Left values
  where
    registry = journalAccountRegistry journal
    errors = sourceErrors ++ journalErrors
    sourceErrors = concatMap validateSourceAccount (Map.toAscList accounts)
    journalErrors =
      [ sourceError "actual.journal" 0
          ("actual.journal Account is missing from accounts.tsv: "
            <> accountName account)
      | declaration <- accountDeclarations registry
      , let account = declaredAccount declaration
      , Map.notMember account accounts
      ]
    validateSourceAccount (account, fact) =
      case lookupAccountDeclaration account registry of
        Nothing ->
          [ sourceError "accounts.tsv" 0
              ("accounts.tsv Account is not declared in actual.journal: "
                <> accountName account)
          ]
        Just declaration
          | declaredAccountType declaration == accountFactRole fact -> []
          | otherwise ->
              [ sourceError "accounts.tsv" 0
                  ("Account type disagrees between accounts.tsv and actual.journal for "
                    <> accountName account
                    <> ": accounts.tsv=" <> tshow (accountFactRole fact)
                    <> ", actual.journal=" <> tshow (declaredAccountType declaration))
              ]

resolveCycles
  :: Day
  -> Journal
  -> Account
  -> [IncomingCycleAnchor]
  -> Either (NonEmpty HouseholdSourceError) (Period, Period)
resolveCycles observation journal incomeAccount anchors =
  case (reverse actualAnchors, plannedAnchors) of
    (currentStart : previousStart : _, currentEnd : _) -> do
      current <- period currentStart currentEnd
      previous <- period previousStart currentStart
      Right (current, previous)
    _ -> Left (sourceError "household.toml" 0
      "income-anchor cycle requires two observed Actual anchors and one future Plan anchor"
      NonEmpty.:| [])
  where
    actualAnchors = Set.toAscList (Set.fromList
      [ entryDate entry
      | entry <- journalEntries journal
      , entryDate entry <= observation
      , entryAccount entry == incomeAccount
      , amountQuantity (entryAmount entry) < zeroQuantity
      ])
    plannedAnchors = Set.toAscList (Set.fromList
      [ incomingAnchorDate anchor
      | anchor <- anchors
      , incomingAnchorSource anchor == incomeAccount
      , incomingAnchorDate anchor > observation
      ])
    period start end = mapLeft
      (NonEmpty.singleton . sourceError "household.toml" 0 . tshow)
      (mkPeriod start end)

openPlansInPeriod
  :: Period
  -> AccountRegistry
  -> Set.Set PlanId
  -> [PlanFact]
  -> [PlanFact]
openPlansInPeriod period registry openPlanIds =
  sortOn (committedPlanDate . planFactValue)
    . filter eligible
  where
    eligible plan =
      Set.member (committedPlanId (planFactValue plan)) openPlanIds
        && periodContains period (committedPlanDate (planFactValue plan))
        && accountTypeFor (planFactFrom plan) registry == Just Asset
        && accountTypeFor (planFactTo plan) registry
          `elem` [Just Expense, Just Liability]

collectUnique
  :: Ord key
  => Text
  -> (value -> key)
  -> [value]
  -> Either (NonEmpty HouseholdSourceError) (Map key value)
collectUnique source keyOf values = case duplicates of
  [] -> Right (Map.fromList [(keyOf value, value) | value <- values])
  _ -> Left (sourceError source 0 "duplicate identity" NonEmpty.:| [])
  where
    duplicates = duplicateKeys keyOf values

duplicateKeys :: Ord key => (value -> key) -> [value] -> [key]
duplicateKeys keyOf values =
  [ key
  | (key, count) <- Map.toAscList
      (Map.fromListWith (+) [(keyOf value, 1 :: Int) | value <- values])
  , count > 1
  ]

requireField
  :: Text
  -> Int
  -> Text
  -> Map Text Text
  -> Either HouseholdSourceError Text
requireField source lineNumber field metadata =
  maybe (Left (sourceError source lineNumber ("missing " <> field))) Right
    (Map.lookup field metadata)

mapLeft :: (left -> right) -> Either left value -> Either right value
mapLeft f result = case result of
  Left err -> Left (f err)
  Right value -> Right value

tshow :: Show value => value -> Text
tshow = T.pack . show
