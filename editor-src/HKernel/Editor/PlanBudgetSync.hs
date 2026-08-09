{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.PlanBudgetSync
  ( PlanBudgetSyncError(..)
  , PlanBudgetSyncPreview(..)
  , PlanBudgetSyncResult(..)
  , preparePlanBudgetSync
  ) where

import Data.Char (isSpace)
import Data.List (findIndex)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account (Account, AccountRegistry)
import HKernel.Actual.Journal
  ( ActualJournal
  , actualJournalCompletionDeclarations
  , actualJournalTransactionEntries
  , actualTransactionEntryIdentity
  , actualTransactionEntryTransaction
  )
import HKernel.Editor.BudgetMovementAppend
  ( BudgetJournalMovementAppendError
  , BudgetJournalMovementAppendPreview(..)
  , prepareBudgetJournalMovementAppend
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Household.AccountProfile
  ( HouseholdAccountPolicy
  , RetainedAccountPolicyValue(..)
  , householdBudgetKindByAccount
  , householdEnvelopeRoleByAccount
  , householdSpendClassByAccount
  )
import HKernel.Household.BudgetMovement
  ( HouseholdBudgetMovement(..)
  , admitHouseholdBudgetMovementJournal
  )
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdAllocationEnvelopes
  , householdEnvelopeForPlanDestination
  )
import HKernel.Journal (Journal)
import HKernel.Ledger
  ( Posting
  , Transaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Amount
  , amountCommodity
  , amountQuantity
  , quantityToRational
  )
import HKernel.Plan (PlanId, planIdText)
import HKernel.Plan.Completion
  ( actualTransactionIdText
  , declaredCompletionActualId
  , declaredCompletionPlanId
  )
import HKernel.Plan.Journal
  ( PlanJournal
  , identifiedPlanId
  , identifiedPlanTransaction
  , planJournalTransactions
  )

data PlanBudgetSyncError
  = PlanBudgetSyncPlanMissing PlanId
  | PlanBudgetSyncPlanDuplicate PlanId
  | PlanBudgetSyncCompletionMissing PlanId
  | PlanBudgetSyncCompletionDuplicate PlanId
  | PlanBudgetSyncActualMissing PlanId
  | PlanBudgetSyncShapeMismatch PlanId
  | PlanBudgetSyncDirectionMismatch PlanId
  | PlanBudgetSyncMultipleDestinations PlanId
  | PlanBudgetSyncDestinationNotFixed Account
  | PlanBudgetSyncEnvelopeAllocationMissing PlanId
  | PlanBudgetSyncEnvelopeNotExecution Account
  | PlanBudgetSyncSpentAccountMissing
  | PlanBudgetSyncSpentAccountDuplicate (NonEmpty Account)
  | PlanBudgetSyncActualAmountNotPositive PlanId
  | PlanBudgetSyncCommodityMismatch PlanId
  | PlanBudgetSyncActualMetadataAlignmentMismatch Int Int
  | PlanBudgetSyncBudgetMetadataAlignmentMismatch Int Int
  | PlanBudgetSyncDuplicateMetadataKey Text
  | PlanBudgetSyncDuplicateBudgetLinkage PlanId
  | PlanBudgetSyncExistingLinkageMismatch PlanId
  | PlanBudgetSyncBudgetCandidateError (NonEmpty BudgetJournalMovementAppendError)
  deriving (Eq, Show)

data PlanBudgetSyncPreview = PlanBudgetSyncPreview
  { planBudgetSyncPlanId                  :: PlanId
  , planBudgetSyncCandidateBlock          :: Text
  , planBudgetSyncCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanBudgetSyncResult
  = PlanBudgetSyncNotLinked PlanId
  | PlanBudgetSyncApplied PlanId
  | PlanBudgetSyncAppend PlanBudgetSyncPreview
  deriving (Eq, Show)

preparePlanBudgetSync
  :: AccountRegistry
  -> HouseholdPolicy
  -> Maybe HouseholdAccountPolicy
  -> PlanJournal
  -> ActualJournal
  -> Text
  -> Journal
  -> Text
  -> PlanId
  -> Either (NonEmpty PlanBudgetSyncError) PlanBudgetSyncResult
preparePlanBudgetSync registry policy maybeAccountPolicy planJournal actualJournal actualRootSource budgetJournal budgetRootSource planId = do
  planTransaction <- uniquePlanTransaction
  (actualIndex, actualTransaction) <- uniqueCompletedActual
  verifyCompletionShape planTransaction actualTransaction
  case mappedDestination planTransaction of
    Nothing -> Right (PlanBudgetSyncNotLinked planId)
    Just (postingIndex, expenseAccount, envelopeId) -> do
      accountPolicy <- case maybeAccountPolicy of
        Nothing -> failOne (PlanBudgetSyncDestinationNotFixed expenseAccount)
        Just value -> Right value
      requireFixedDestination accountPolicy expenseAccount
      fromAccount <- case Map.lookup envelopeId (householdAllocationEnvelopes policy) of
        Nothing -> failOne (PlanBudgetSyncEnvelopeAllocationMissing planId)
        Just value -> Right value
      requireExecutionEnvelope accountPolicy fromAccount
      toAccount <- uniqueSpentAccount accountPolicy
      actualPosting <- postingAt postingIndex actualTransaction
      planPosting <- postingAt postingIndex planTransaction
      let actualAmount = postingAmount actualPosting
      if quantityToRational (amountQuantity actualAmount) <= 0
        then failOne (PlanBudgetSyncActualAmountNotPositive planId)
        else Right ()
      if amountCommodity (postingAmount planPosting) /= amountCommodity actualAmount
        then failOne (PlanBudgetSyncCommodityMismatch planId)
        else Right ()
      durableActualId <- durableEventIdAt actualIndex
      let movement = HouseholdBudgetMovement
            { householdBudgetMovementDate = transactionDate actualTransaction
            , householdBudgetMovementMemo = "Plan completion Budget sync: " <> planIdText planId
            , householdBudgetMovementFrom = fromAccount
            , householdBudgetMovementTo = toAccount
            , householdBudgetMovementAmount = actualAmount
            }
          metadata = expectedMetadata planId durableActualId
      classifyExisting movement metadata
  where
    failOne = Left . NonEmpty.singleton

    planMatches =
      [ identifiedPlanTransaction identified
      | identified <- planJournalTransactions planJournal
      , identifiedPlanId identified == planId
      ]
    uniquePlanTransaction = case planMatches of
      [] -> failOne (PlanBudgetSyncPlanMissing planId)
      [transaction] -> Right transaction
      _ -> failOne (PlanBudgetSyncPlanDuplicate planId)

    completionMatches =
      [ declaredCompletionActualId declaration
      | declaration <- actualJournalCompletionDeclarations actualJournal
      , declaredCompletionPlanId declaration == planId
      ]
    uniqueCompletedActual = case completionMatches of
      [] -> failOne (PlanBudgetSyncCompletionMissing planId)
      [actualId] -> case findIndex
          ((== Just actualId) . actualTransactionEntryIdentity)
          (actualJournalTransactionEntries actualJournal) of
        Nothing -> failOne (PlanBudgetSyncActualMissing planId)
        Just index -> Right
          ( index
          , actualTransactionEntryTransaction
              (actualJournalTransactionEntries actualJournal !! index)
          )
      _ -> failOne (PlanBudgetSyncCompletionDuplicate planId)

    verifyCompletionShape planTransaction actualTransaction = do
      let planPostings = NonEmpty.toList (transactionPostings planTransaction)
          actualPostings = NonEmpty.toList (transactionPostings actualTransaction)
          planAccounts = map postingAccount planPostings
          actualAccounts = map postingAccount actualPostings
          directions = map (signOf . postingAmount)
      if planAccounts /= actualAccounts
        then failOne (PlanBudgetSyncShapeMismatch planId)
        else Right ()
      if directions planPostings /= directions actualPostings
        then failOne (PlanBudgetSyncDirectionMismatch planId)
        else Right ()

    signOf amount = compare (quantityToRational (amountQuantity amount)) 0

    mappedDestination transaction =
      case mapMaybe classify (zip [0..] (NonEmpty.toList (transactionPostings transaction))) of
        [] -> Right Nothing
        [(index, account, envelopeId)] -> Right (Just (index, account, envelopeId))
        _ -> failOne (PlanBudgetSyncMultipleDestinations planId)
      where
        classify (index, posting) =
          let account = postingAccount posting
          in case householdEnvelopeForPlanDestination policy account of
            Nothing -> Nothing
            Just envelopeId -> Just (index, account, envelopeId)

    requireFixedDestination accountPolicy expenseAccount =
      case Map.lookup expenseAccount (householdSpendClassByAccount accountPolicy) of
        Just RetainedFixedSpend -> Right ()
        _ -> failOne (PlanBudgetSyncDestinationNotFixed expenseAccount)

    requireExecutionEnvelope accountPolicy allocationAccount =
      case Map.lookup allocationAccount (householdEnvelopeRoleByAccount accountPolicy) of
        Just RetainedExecutionEnvelopeRole -> Right ()
        _ -> failOne (PlanBudgetSyncEnvelopeNotExecution allocationAccount)

    uniqueSpentAccount accountPolicy = case
        [ account
        | (account, kind) <- Map.toList (householdBudgetKindByAccount accountPolicy)
        , kind == RetainedSpentBudgetAccount
        ] of
      [] -> failOne PlanBudgetSyncSpentAccountMissing
      [account] -> Right account
      firstAccount : rest ->
        Left (NonEmpty.singleton
          (PlanBudgetSyncSpentAccountDuplicate (firstAccount NonEmpty.:| rest)))

    postingAt index transaction = case drop index (NonEmpty.toList (transactionPostings transaction)) of
      posting : _ -> Right posting
      [] -> failOne (PlanBudgetSyncShapeMismatch planId)

    actualMetadataBlocks = transactionMetadataBlocks actualRootSource
    actualEntries = actualJournalTransactionEntries actualJournal
    durableEventIdAt index
      | length actualMetadataBlocks /= length actualEntries =
          failOne (PlanBudgetSyncActualMetadataAlignmentMismatch
            (length actualEntries) (length actualMetadataBlocks))
      | otherwise = metadataOptional "event-id" (actualMetadataBlocks !! index)

    budgetMovements = case admitHouseholdBudgetMovementJournal budgetJournal of
      Left _ -> []
      Right values -> values
    budgetMetadataBlocks = transactionMetadataBlocks budgetRootSource

    classifyExisting movement metadata
      | length budgetMetadataBlocks /= length budgetMovements =
          failOne (PlanBudgetSyncBudgetMetadataAlignmentMismatch
            (length budgetMovements) (length budgetMetadataBlocks))
      | otherwise = do
          matching <- matchingBudgetIndices budgetMetadataBlocks
          case matching of
            [] -> appendCandidate movement metadata
            [index]
              | budgetMovements !! index == movement
                  && budgetMetadataBlocks !! index == metadata ->
                    Right (PlanBudgetSyncApplied planId)
              | otherwise -> failOne (PlanBudgetSyncExistingLinkageMismatch planId)
            _ -> failOne (PlanBudgetSyncDuplicateBudgetLinkage planId)

    matchingBudgetIndices blocks =
      traverse classify (zip [0..] blocks) >>= Right . mapMaybe id
      where
        classify (index, blockMetadata) = do
          value <- metadataOptional "plan-id" blockMetadata
          Right $ if value == Just (planIdText planId) then Just index else Nothing

    appendCandidate movement metadata = case
        prepareBudgetJournalMovementAppend registry budgetRootSource movement of
      Left errors -> Left
        (NonEmpty.singleton (PlanBudgetSyncBudgetCandidateError errors))
      Right basePreview ->
        let block = injectMetadata metadata (budgetJournalCandidateBlock basePreview)
            completeSource = appendSourceBlock budgetRootSource (SourceBlock block)
        in Right (PlanBudgetSyncAppend PlanBudgetSyncPreview
            { planBudgetSyncPlanId = planId
            , planBudgetSyncCandidateBlock = block
            , planBudgetSyncCandidateCompleteSource = completeSource
            })

expectedMetadata :: PlanId -> Maybe Text -> [(Text, Text)]
expectedMetadata planId maybeActualEvent =
  [ ("layer", "budget")
  , ("event-id", "budget-sync-" <> planIdText planId)
  , ("plan-id", planIdText planId)
  ] ++ maybe [] (\actualEvent -> [("actual-event-id", actualEvent)]) maybeActualEvent

injectMetadata :: [(Text, Text)] -> Text -> Text
injectMetadata metadata block = case T.lines block of
  [] -> block
  header : rest -> T.unlines
    (header : map renderMetadata metadata ++ rest)
  where
    renderMetadata (key, value) = "  ; " <> key <> ": " <> value

transactionMetadataBlocks :: Text -> [[(Text, Text)]]
transactionMetadataBlocks input =
  [ mapMaybe parseMetadata (drop 1 block)
  | block@((_, header) : _) <- sourceBlocks input
  , not (isNonTransactionDirective header)
  ]

sourceBlocks :: Text -> [[(Int, Text)]]
sourceBlocks = map reverse . reverse . foldl addLine [] . zip [1..] . T.lines
  where
    addLine blocks located@(_, line)
      | startsBlock line = [located] : blocks
      | otherwise = case blocks of
          [] -> []
          block : rest -> (located : block) : rest

startsBlock :: Text -> Bool
startsBlock line =
  not (T.null (T.strip line))
    && not (isIndented line)
    && not (isComment line)

parseMetadata :: (Int, Text) -> Maybe (Text, Text)
parseMetadata (_, line)
  | not (isIndented line && isComment line) = Nothing
  | otherwise = case T.breakOn ":" cleanLine of
      (_, remainder) | T.null remainder -> Nothing
      (rawKey, remainder) -> Just
        (T.toCaseFold (T.strip rawKey), T.strip (T.drop 1 remainder))
  where
    cleanLine = T.strip
      (T.dropWhile (\character -> character == ';' || isSpace character)
        (T.strip line))

metadataOptional
  :: Text
  -> [(Text, Text)]
  -> Either (NonEmpty PlanBudgetSyncError) (Maybe Text)
metadataOptional key metadata = case [value | (entryKey, value) <- metadata, entryKey == key] of
  [] -> Right Nothing
  [value] -> Right (Just value)
  _ -> Left (NonEmpty.singleton (PlanBudgetSyncDuplicateMetadataKey key))

isNonTransactionDirective :: Text -> Bool
isNonTransactionDirective line =
  any (`isDirective` line) ["account", "include", "commodity"]

isDirective :: Text -> Text -> Bool
isDirective keyword line = case T.stripPrefix keyword (T.stripStart line) of
  Nothing -> False
  Just remainder ->
    T.null remainder
      || maybe False (isSpace . fst) (T.uncons remainder)

isComment :: Text -> Bool
isComment = T.isPrefixOf ";" . T.stripStart

isIndented :: Text -> Bool
isIndented line = case T.uncons line of
  Just (character, _) -> isSpace character
  Nothing -> False
