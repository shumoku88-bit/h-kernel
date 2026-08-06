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

import HKernel.Actual.Journal (ActualJournalError, parseActualJournal, actualJournalCompletionDeclarations)
import HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
  , prepareActualAppend
  )
import HKernel.Editor.ActualIdentity
  ( actualEventIdentityMetadata
  , actualIdentityIsAlreadyUsed
  , admitActualEventIdentityText
  )
import HKernel.Editor.SourceAppend (appendSourceBlock)
import HKernel.Editor.TransactionBlock
  ( IntentPosting(..)
  , TransactionBlockIntent(..)
  , TransactionBlockError
  , prepareTransactionBlock
  )
import HKernel.Journal (journalAccountRegistry)
import HKernel.Ledger (transactionDescription, transactionPostings, postingAccount, postingAmount, mkPosting)
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
import HKernel.Plan.Journal
  ( PlanJournalError
  , parsePlanJournal
  , planJournalValue
  , planJournalTransactions
  , identifiedPlanId
  , identifiedPlanTransaction
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , declaredCompletionPlanId
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
slugify t =
  let
    mapped = T.map (\c -> if isAsciiUpper c then toLower c else if isAsciiLower c || (c >= '0' && c <= '9') then c else '-') t
    collapsed = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" mapped))
  in collapsed

generatePlanId
  :: Day
  -> Text
  -> Maybe Text
  -> [PlanId]
  -> Either PlanIdError PlanId
generatePlanId date desc mSeries existingIds = go 1
  where
    prefix = "plan-" <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" date) <> "-"
    suffix = case mSeries of
      Just series -> series
      Nothing ->
        let slug = slugify desc
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
  planJ <- first (pure . AddPlanJournalSyntaxError) (parsePlanJournal planSource)
  actualJ <- first (pure . AddActualJournalSyntaxError) (parseActualJournal actualSource)

  let existingPlanIds = map identifiedPlanId (planJournalTransactions planJ)
                        ++ map declaredCompletionPlanId (actualJournalCompletionDeclarations actualJ)

  newPlanId <- case addRequestedId intent of
    Nothing -> first (pure . AddGeneratedIdError)
      (generatePlanId
        (addDate intent)
        (addDescription intent)
        (addSeries intent)
        existingPlanIds)
    Just requested -> do
      pId <- first (pure . AddInvalidId) (mkPlanId requested)
      if pId `elem` existingPlanIds
        then Left (pure (AddDuplicateId pId))
        else Right pId

  let blockIntent = TransactionBlockIntent
        { blockDate = addDate intent
        , blockDescription = addDescription intent
        , blockPostings = addPostings intent
        , blockMetadata = [("plan-id", planIdText newPlanId)]
        }

  block <- first (pure . AddTransactionBlockError)
    (prepareTransactionBlock
      (journalAccountRegistry (planJournalValue planJ))
      blockIntent)

  let preview = PlanAddPreview
        { addCandidateBlock = block
        , addCandidateCompleteSource = appendSourceBlock planSource block
        }

  _ <- first (pure . AddCandidateParseError) (parsePlanJournal (addCandidateCompleteSource preview))

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
  { finishPlanId        :: Text
  , finishActualEventId :: ActualTransactionId
  , finishActualDate    :: Day
  , finishActualAmount  :: Maybe PositivePlanFinishAmount
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
  | FinishInvalidActualEventIdentity
  | FinishActualEventIdentityAlreadyExists
  deriving (Eq, Show)

preparePlanFinish
  :: Text
  -> Text
  -> PlanFinishIntent
  -> Either (NonEmpty PlanFinishError) PlanFinishPreview
preparePlanFinish planSource actualSource intent = do
  planJ <- first (pure . FinishPlanJournalSyntaxError) (parsePlanJournal planSource)
  actualJ <- first (pure . FinishActualJournalSyntaxError) (parseActualJournal actualSource)

  pId <- first (pure . FinishInvalidId) (mkPlanId (finishPlanId intent))

  let existingCompletions = map declaredCompletionPlanId (actualJournalCompletionDeclarations actualJ)
  if pId `elem` existingCompletions
    then Left (pure (FinishPlanAlreadyClosed pId))
    else Right ()

  let planTransactions = planJournalTransactions planJ
  identifiedPlanTx <- case filter (\p -> identifiedPlanId p == pId) planTransactions of
    [] -> Left (pure (FinishPlanNotFound pId))
    (p:_) -> Right p

  let txn = identifiedPlanTransaction identifiedPlanTx
      originalPostings = transactionPostings txn

  updatedPostings <- case finishActualAmount intent of
    Nothing -> Right originalPostings
    Just positiveAmount ->
      if length originalPostings /= 2
        then Left (pure FinishActualAmountOnlyForBinaryPlan)
        else
          let
            newQty = positivePlanFinishAmountQuantity positiveAmount
            modifyPosting p =
              let oldQty = amountQuantity (postingAmount p)
                  qty = if quantityToRational oldQty < 0 then negateQuantity newQty else newQty
              in mkPosting (postingAccount p) (mkAmount (amountCommodity (postingAmount p)) qty)
          in Right (fmap modifyPosting originalPostings)

  canonicalEventId <- first (const (pure FinishInvalidActualEventIdentity))
    (admitActualEventIdentityText (actualTransactionIdText (finishActualEventId intent)))

  if actualIdentityIsAlreadyUsed actualJ canonicalEventId
    then Left (pure FinishActualEventIdentityAlreadyExists)
    else Right ()

  let finishIntentPostings = fmap (\p -> IntentPosting (postingAccount p) (amountQuantity (postingAmount p)) (Just (amountCommodity (postingAmount p)))) updatedPostings

  let actualIntent = ActualEditIntent
        { intentDate = finishActualDate intent
        , intentDescription = transactionDescription txn
        , intentPostings = finishIntentPostings
        , intentMetadata =
            [ actualEventIdentityMetadata canonicalEventId
            , ("plan-id", planIdText pId)
            ]
        }

  actualPreview <- first (pure . FinishActualEditError) (prepareActualAppend actualSource actualIntent)

  let preview = PlanFinishPreview
        { finishCandidateBlock = candidateBlock actualPreview
        , finishCandidateCompleteSource = candidateCompleteSource actualPreview
        }

  _ <- first (pure . FinishCandidateParseError) (parseActualJournal (finishCandidateCompleteSource preview))

  pure preview

