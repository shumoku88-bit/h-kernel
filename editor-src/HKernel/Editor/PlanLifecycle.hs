{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanAddPreview(..)
  , PlanAddError(..)
  , preparePlanAdd

  , PositivePlanFinishAmount
  , PlanFinishAmountError(..)
  , mkPositivePlanFinishAmount
  , positivePlanFinishAmountQuantity
  , PlanFinishIntent(..)
  , PlanFinishPreview(..)
  , PlanFinishError(..)
  , preparePlanFinish
  ) where

import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, toLower)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Actual.Journal
  ( ActualJournalError
  , actualJournalCompletionDeclarations
  , parseActualJournal
  )
import HKernel.Editor.ActualAppend
  ( ActualAppendPreview(..)
  , ActualEditError
  , ActualEditIntent(..)
  , IntentPosting(..)
  , TransactionBlockError
  , TransactionBlockIntent(..)
  , appendBlock
  , prepareActualAppend
  , prepareTransactionBlock
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Ledger
  ( mkPosting
  , postingAccount
  , postingAmount
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Quantity
  , amountCommodity
  , amountQuantity
  , mkAmount
  , negateQuantity
  , quantityToRational
  , zeroQuantity
  )
import HKernel.Plan
  ( PlanId
  , PlanIdError
  , mkPlanId
  , planIdText
  )
import HKernel.Plan.Completion (declaredCompletionPlanId)
import HKernel.Plan.Journal
  ( PlanJournalError
  , identifiedPlanId
  , identifiedPlanTransaction
  , parsePlanJournal
  , planJournalTransactions
  , planJournalValue
  )

-- Plan Add

data PlanAddIntent = PlanAddIntent
  { addDate        :: Day
  , addDescription :: Text
  , addPostings    :: NonEmpty IntentPosting
  , addRequestedId :: Maybe Text
  , addSeries      :: Maybe Text
  } deriving (Eq, Show)

data PlanAddPreview = PlanAddPreview
  { addCandidateBlock          :: Text
  , addCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanAddError
  = AddPlanJournalSyntaxError (NonEmpty PlanJournalError)
  | AddActualJournalSyntaxError (NonEmpty ActualJournalError)
  | AddTransactionBlockError (NonEmpty TransactionBlockError)
  | AddCandidateParseError (NonEmpty PlanJournalError)
  | AddDuplicateId PlanId
  | AddInvalidId PlanIdError
  | AddGeneratedIdError PlanIdError
  deriving (Eq, Show)

slugify :: Text -> Text
slugify text =
  let
    mapped = T.map
      (\character ->
        if isAsciiUpper character
          then toLower character
          else if isAsciiLower character
            || (character >= '0' && character <= '9')
            then character
            else '-')
      text
    collapsed = T.intercalate "-"
      (filter (not . T.null) (T.splitOn "-" mapped))
  in collapsed

generatePlanId
  :: Day
  -> Text
  -> Maybe Text
  -> [PlanId]
  -> Either PlanIdError PlanId
generatePlanId date description maybeSeries existingIds = go 1
  where
    prefix =
      "plan-"
      <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" date)
      <> "-"
    suffix = case maybeSeries of
      Just series -> series
      Nothing ->
        let slug = slugify description
        in if T.null slug then "plan" else slug
    base = prefix <> suffix

    candidateText candidateNumber
      | candidateNumber == 1 = base
      | candidateNumber < 10 =
          base <> "-0" <> T.pack (show candidateNumber)
      | otherwise = base <> "-" <> T.pack (show candidateNumber)

    go candidateNumber = do
      candidateId <- mkPlanId (candidateText candidateNumber)
      if candidateId `elem` existingIds
        then go (candidateNumber + 1)
        else Right candidateId

preparePlanAdd
  :: Text
  -> Text
  -> PlanAddIntent
  -> Either (NonEmpty PlanAddError) PlanAddPreview
preparePlanAdd planSource actualSource intent = do
  planJournal <- first (pure . AddPlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJournal <- first (pure . AddActualJournalSyntaxError)
    (parseActualJournal actualSource)

  let existingPlanIds =
        map identifiedPlanId (planJournalTransactions planJournal)
        ++ map declaredCompletionPlanId
          (actualJournalCompletionDeclarations actualJournal)

  newPlanId <- case addRequestedId intent of
    Nothing -> first (pure . AddGeneratedIdError)
      (generatePlanId
        (addDate intent)
        (addDescription intent)
        (addSeries intent)
        existingPlanIds)
    Just requested -> do
      planId <- first (pure . AddInvalidId) (mkPlanId requested)
      if planId `elem` existingPlanIds
        then Left (pure (AddDuplicateId planId))
        else Right planId

  let blockIntent = TransactionBlockIntent
        { blockDate = addDate intent
        , blockDescription = addDescription intent
        , blockPostings = addPostings intent
        , blockMetadata = [("plan-id", planIdText newPlanId)]
        }
      planRegistry =
        journalAccountRegistry (planJournalValue planJournal)

  block <- first (pure . AddTransactionBlockError)
    (prepareTransactionBlock planRegistry blockIntent)

  let preview = PlanAddPreview
        { addCandidateBlock = block
        , addCandidateCompleteSource = appendBlock planSource block
        }

  _ <- first (pure . AddCandidateParseError)
    (parsePlanJournal (addCandidateCompleteSource preview))

  pure preview


-- Plan Finish

-- | A strictly positive magnitude supplied when a binary Plan is finished.
-- The original posting signs remain the owner of payment direction.
newtype PositivePlanFinishAmount = PositivePlanFinishAmount
  { positivePlanFinishAmountQuantity :: Quantity
  } deriving (Eq, Show)

data PlanFinishAmountError
  = NonPositivePlanFinishAmount Quantity
  deriving (Eq, Show)

mkPositivePlanFinishAmount
  :: Quantity
  -> Either PlanFinishAmountError PositivePlanFinishAmount
mkPositivePlanFinishAmount quantity
  | quantity <= zeroQuantity = Left (NonPositivePlanFinishAmount quantity)
  | otherwise = Right (PositivePlanFinishAmount quantity)

data PlanFinishIntent = PlanFinishIntent
  { finishPlanId       :: Text
  , finishActualDate   :: Day
  , finishActualAmount :: Maybe PositivePlanFinishAmount
  } deriving (Eq, Show)

data PlanFinishPreview = PlanFinishPreview
  { finishCandidateBlock          :: Text
  , finishCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanFinishError
  = FinishPlanJournalSyntaxError (NonEmpty PlanJournalError)
  | FinishActualJournalSyntaxError (NonEmpty ActualJournalError)
  | FinishActualEditError (NonEmpty ActualEditError)
  | FinishCandidateParseError (NonEmpty ActualJournalError)
  | FinishInvalidId PlanIdError
  | FinishPlanNotFound PlanId
  | FinishPlanAlreadyClosed PlanId
  | FinishActualAmountOnlyForBinaryPlan
  deriving (Eq, Show)

preparePlanFinish
  :: Text
  -> Text
  -> PlanFinishIntent
  -> Either (NonEmpty PlanFinishError) PlanFinishPreview
preparePlanFinish planSource actualSource intent = do
  planJournal <- first (pure . FinishPlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJournal <- first (pure . FinishActualJournalSyntaxError)
    (parseActualJournal actualSource)

  planId <- first (pure . FinishInvalidId)
    (mkPlanId (finishPlanId intent))

  let existingCompletions = map declaredCompletionPlanId
        (actualJournalCompletionDeclarations actualJournal)
  if planId `elem` existingCompletions
    then Left (pure (FinishPlanAlreadyClosed planId))
    else Right ()

  identifiedPlan <- case filter
    ((== planId) . identifiedPlanId)
    (planJournalTransactions planJournal) of
      [] -> Left (pure (FinishPlanNotFound planId))
      plan : _ -> Right plan

  let transaction = identifiedPlanTransaction identifiedPlan
      originalPostings = transactionPostings transaction

  updatedPostings <- case finishActualAmount intent of
    Nothing -> Right originalPostings
    Just positiveAmount ->
      if length originalPostings /= 2
        then Left (pure FinishActualAmountOnlyForBinaryPlan)
        else
          let
            newQuantity =
              positivePlanFinishAmountQuantity positiveAmount
            modifyPosting posting =
              let
                oldQuantity = amountQuantity (postingAmount posting)
                quantity =
                  if quantityToRational oldQuantity < 0
                    then negateQuantity newQuantity
                    else newQuantity
              in mkPosting
                  (postingAccount posting)
                  (mkAmount
                    (amountCommodity (postingAmount posting))
                    quantity)
          in Right (fmap modifyPosting originalPostings)

  let intentPostings = fmap
        (\posting -> IntentPosting
          (postingAccount posting)
          (amountQuantity (postingAmount posting))
          (Just (amountCommodity (postingAmount posting))))
        updatedPostings
      actualIntent = ActualEditIntent
        { intentDate = finishActualDate intent
        , intentDescription = transactionDescription transaction
        , intentPostings = intentPostings
        , intentMetadata = [("plan-id", planIdText planId)]
        }

  actualPreview <- first (pure . FinishActualEditError)
    (prepareActualAppend actualSource actualIntent)

  let preview = PlanFinishPreview
        { finishCandidateBlock = candidateBlock actualPreview
        , finishCandidateCompleteSource =
            candidateCompleteSource actualPreview
        }

  _ <- first (pure . FinishCandidateParseError)
    (parseActualJournal (finishCandidateCompleteSource preview))

  pure preview
