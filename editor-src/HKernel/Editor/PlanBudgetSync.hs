{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.PlanBudgetSync
  ( PlanBudgetSyncError(..)
  , PlanBudgetSyncPreview(..)
  , PlanBudgetSyncResult(..)
  , preparePlanBudgetSync
  ) where

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
  , RetainedBudgetAccountKind(..)
  , RetainedEnvelopeRole(..)
  , RetainedSpendClass(..)
  , householdBudgetKindByAccount
  , householdEnvelopeRoleByAccount
  , householdSpendClassByAccount
  )
import HKernel.Household.BudgetMovement (HouseholdBudgetMovement(..))
import HKernel.Household.Policy
  ( HouseholdPolicy
  , householdAllocationEnvelopes
  , householdEnvelopeForPlanDestination
  )
import HKernel.Journal
  ( journalDocumentTransactionSources
  , journalErrorLine
  , journalMetadataKey
  , journalMetadataValue
  , journalTransactionSourceMetadata
  , parseJournalDocument
  )
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionPostings
  )
import HKernel.Money
  ( amountCommodity
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
  | PlanBudgetSyncEnvelopeAllocationDuplicate PlanId (NonEmpty Account)
  | PlanBudgetSyncEnvelopeNotExecution Account
  | PlanBudgetSyncSpentAccountMissing
  | PlanBudgetSyncSpentAccountDuplicate (NonEmpty Account)
  | PlanBudgetSyncActualAmountNotPositive PlanId
  | PlanBudgetSyncCommodityMismatch PlanId
  | PlanBudgetSyncBudgetJournalSyntaxError Int
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
  -> [HouseholdBudgetMovement]
  -> Text
  -> PlanId
  -> Either (NonEmpty PlanBudgetSyncError) PlanBudgetSyncResult
preparePlanBudgetSync registry policy maybeAccountPolicy planJournal actualJournal budgetMovements budgetRootSource planId = do
  planTransaction <- uniquePlanTransaction
  (actualId, actualTransaction) <- uniqueCompletedActual
  verifyCompletionShape planTransaction actualTransaction
  destination <- mappedDestination planTransaction
  case destination of
    Nothing -> Right (PlanBudgetSyncNotLinked planId)
    Just (postingIndex, expenseAccount, envelopeId) -> do
      accountPolicy <- case maybeAccountPolicy of
        Nothing -> failOne (PlanBudgetSyncDestinationNotFixed expenseAccount)
        Just value -> Right value
      requireFixedDestination accountPolicy expenseAccount
      fromAccount <- uniqueAllocationAccount envelopeId
      requireExecutionEnvelope accountPolicy fromAccount
      toAccount <- uniqueSpentAccount accountPolicy
      actualPosting <- postingAt postingIndex actualTransaction
      let actualAmount = postingAmount actualPosting
      if quantityToRational (amountQuantity actualAmount) <= 0
        then failOne (PlanBudgetSyncActualAmountNotPositive planId)
        else Right ()
      let movement = HouseholdBudgetMovement
            { householdBudgetMovementDate = transactionDate actualTransaction
            , householdBudgetMovementMemo = "Plan completion Budget sync: " <> planIdText planId
            , householdBudgetMovementFrom = fromAccount
            , householdBudgetMovementTo = toAccount
            , householdBudgetMovementAmount = actualAmount
            }
          metadata = expectedMetadata planId (actualTransactionIdText actualId)
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
          ( actualId
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
          commodities = map (amountCommodity . postingAmount)
      if planAccounts /= actualAccounts
        then failOne (PlanBudgetSyncShapeMismatch planId)
        else Right ()
      if directions planPostings /= directions actualPostings
        then failOne (PlanBudgetSyncDirectionMismatch planId)
        else Right ()
      if commodities planPostings /= commodities actualPostings
        then failOne (PlanBudgetSyncCommodityMismatch planId)
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
          in case householdEnvelopeForPlanDestination account policy of
            Nothing -> Nothing
            Just envelopeId -> Just (index, account, envelopeId)

    requireFixedDestination accountPolicy expenseAccount =
      case Map.lookup expenseAccount (householdSpendClassByAccount accountPolicy) of
        Just RetainedFixedSpend -> Right ()
        _ -> failOne (PlanBudgetSyncDestinationNotFixed expenseAccount)

    uniqueAllocationAccount envelopeId = case
        [ account
        | (account, assignedEnvelope) <- Map.toList (householdAllocationEnvelopes policy)
        , assignedEnvelope == envelopeId
        ] of
      [] -> failOne (PlanBudgetSyncEnvelopeAllocationMissing planId)
      [account] -> Right account
      firstAccount : rest -> failOne
        (PlanBudgetSyncEnvelopeAllocationDuplicate planId (firstAccount NonEmpty.:| rest))

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
        failOne (PlanBudgetSyncSpentAccountDuplicate (firstAccount NonEmpty.:| rest))

    postingAt index transaction = case drop index (NonEmpty.toList (transactionPostings transaction)) of
      posting : _ -> Right posting
      [] -> failOne (PlanBudgetSyncShapeMismatch planId)

    classifyExisting movement metadata = do
      budgetMetadataBlocks <- budgetTransactionMetadataBlocks budgetRootSource
      if length budgetMetadataBlocks /= length budgetMovements
        then failOne (PlanBudgetSyncBudgetMetadataAlignmentMismatch
          (length budgetMovements) (length budgetMetadataBlocks))
        else do
          matching <- matchingBudgetIndices budgetMetadataBlocks
          case matching of
            [] -> appendCandidate movement metadata
            [index]
              | budgetMovements !! index == movement
                  && budgetMetadataBlocks !! index == metadata ->
                    Right (PlanBudgetSyncApplied planId)
              | otherwise -> failOne (PlanBudgetSyncExistingLinkageMismatch planId)
            _ -> failOne (PlanBudgetSyncDuplicateBudgetLinkage planId)

    matchingBudgetIndices blocks = do
      matches <- traverse classify (zip [0..] blocks)
      Right (mapMaybe id matches)
      where
        classify (index, blockMetadata) = do
          value <- metadataOptional "plan-id" blockMetadata
          Right $ if value == Just (planIdText planId) then Just index else Nothing

    appendCandidate movement metadata = case
        prepareBudgetJournalMovementAppend registry budgetRootSource movement of
      Left errors -> failOne (PlanBudgetSyncBudgetCandidateError errors)
      Right basePreview ->
        let block = injectMetadata metadata (budgetJournalCandidateBlock basePreview)
            completeSource = appendSourceBlock budgetRootSource (SourceBlock block)
        in Right (PlanBudgetSyncAppend PlanBudgetSyncPreview
            { planBudgetSyncPlanId = planId
            , planBudgetSyncCandidateBlock = block
            , planBudgetSyncCandidateCompleteSource = completeSource
            })

expectedMetadata :: PlanId -> Text -> [(Text, Text)]
expectedMetadata planId actualEvent =
  [ ("layer", "budget")
  , ("event-id", "budget-sync-" <> planIdText planId)
  , ("plan-id", planIdText planId)
  , ("actual-event-id", actualEvent)
  ]

injectMetadata :: [(Text, Text)] -> Text -> Text
injectMetadata metadata block = case T.lines block of
  [] -> block
  header : rest -> T.unlines
    (header : map renderMetadata metadata ++ rest)
  where
    renderMetadata (key, value) = "  ; " <> key <> ": " <> value

budgetTransactionMetadataBlocks
  :: Text
  -> Either (NonEmpty PlanBudgetSyncError) [[(Text, Text)]]
budgetTransactionMetadataBlocks input =
  case parseJournalDocument input of
    Left journalErrors -> Left
      (fmap (PlanBudgetSyncBudgetJournalSyntaxError . journalErrorLine) journalErrors)
    Right document -> Right
      [ map metadataPair (journalTransactionSourceMetadata source)
      | source <- journalDocumentTransactionSources document
      ]
  where
    metadataPair entry =
      (journalMetadataKey entry, journalMetadataValue entry)

metadataOptional
  :: Text
  -> [(Text, Text)]
  -> Either (NonEmpty PlanBudgetSyncError) (Maybe Text)
metadataOptional key metadata = case [value | (entryKey, value) <- metadata, entryKey == key] of
  [] -> Right Nothing
  [value] -> Right (Just value)
  _ -> Left (NonEmpty.singleton (PlanBudgetSyncDuplicateMetadataKey key))
