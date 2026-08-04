{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanAddPreview(..)
  , PlanAddError(..)
  , preparePlanAdd

  , PlanFinishIntent(..)
  , PlanFinishPreview(..)
  , PlanFinishError(..)
  , preparePlanFinish
  ) where

import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, toLower)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Actual.Journal (ActualJournalError, parseActualJournal, actualJournalCompletionDeclarations)
import HKernel.Editor.ActualAppend
  ( ActualEditIntent(..)
  , IntentPosting(..)
  , ActualEditError(..)
  , ActualAppendPreview(..)
  , prepareActualAppend
  , appendBlock
  )
import HKernel.Ledger (Posting, Transaction, transactionDescription, transactionPostings, postingAccount, postingAmount, mkPosting)
import HKernel.Money (Quantity, mkAmount, amountCommodity, amountQuantity, quantityToRational, negateQuantity)
import HKernel.Plan
  ( PlanId
  , PlanIdError
  , mkPlanId
  , planIdText
  )
import HKernel.Plan.Journal
  ( PlanJournalError
  , parsePlanJournal
  , planJournalTransactions
  , identifiedPlanId
  , identifiedPlanTransaction
  , IdentifiedPlanTransaction
  )
import HKernel.Plan.Completion (declaredCompletionPlanId)

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
  | AddActualEditError (NonEmpty ActualEditError)
  | AddCandidateParseError (NonEmpty PlanJournalError)
  | AddDuplicateId PlanId
  | AddInvalidId PlanIdError
  deriving (Eq, Show)

slugify :: Text -> Text
slugify t =
  let
    mapped = T.map (\c -> if isAsciiUpper c then toLower c else if isAsciiLower c || (c >= '0' && c <= '9') then c else '-') t
    collapsed = T.intercalate "-" (filter (not . T.null) (T.splitOn "-" mapped))
  in collapsed

generatePlanId :: Day -> Text -> Maybe Text -> [PlanId] -> PlanId
generatePlanId date desc mSeries existingIds =
  let
    prefix = "plan-" <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" date) <> "-"
    suffix = case mSeries of
      Just s -> s
      Nothing ->
        let slug = slugify desc
        in if T.null slug then "plan" else slug
    base = prefix <> suffix
    
    candidates = base : [ base <> "-0" <> T.pack (show i) | i <- [(2 :: Int)..9] ]
                 ++ [ base <> "-" <> T.pack (show i) | i <- [(10 :: Int)..] ]
    
    candidateId text = either (error "invalid generated id") id (mkPlanId text)
    isUsed pId = pId `elem` existingIds
  in
    head $ filter (not . isUsed) (map candidateId candidates)

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
    Nothing -> Right (generatePlanId (addDate intent) (addDescription intent) (addSeries intent) existingPlanIds)
    Just requested -> do
      pId <- first (pure . AddInvalidId) (mkPlanId requested)
      if pId `elem` existingPlanIds
        then Left (pure (AddDuplicateId pId))
        else Right pId
        
  let actualIntent = ActualEditIntent
        { intentDate = addDate intent
        , intentDescription = addDescription intent
        , intentPostings = addPostings intent
        , intentMetadata = [("plan-id", planIdText newPlanId)]
        }
  
  -- We reuse prepareActualAppend, but pass planSource because it's generating text for plan.journal!
  actualPreview <- first (pure . AddActualEditError) (prepareActualAppend planSource actualIntent)
  
  let preview = PlanAddPreview
        { addCandidateBlock = candidateBlock actualPreview
        , addCandidateCompleteSource = candidateCompleteSource actualPreview
        }
        
  -- Verify with parsePlanJournal
  _ <- first (pure . AddCandidateParseError) (parsePlanJournal (addCandidateCompleteSource preview))
  
  pure preview


-- Plan Finish

data PlanFinishIntent = PlanFinishIntent
  { finishPlanId      :: Text
  , finishActualDate  :: Day
  , finishActualAmount :: Maybe Quantity
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
    Just newQty ->
      if length originalPostings /= 2
        then Left (pure FinishActualAmountOnlyForBinaryPlan)
        else
          let modifyPosting p =
                let oldQty = amountQuantity (postingAmount p)
                    qty = if quantityToRational oldQty < 0 then negateQuantity newQty else newQty
                in mkPosting (postingAccount p) (mkAmount (amountCommodity (postingAmount p)) qty)
          in Right (fmap modifyPosting originalPostings)
          
  let intentPostings = fmap (\p -> IntentPosting (postingAccount p) (amountQuantity (postingAmount p)) (Just (amountCommodity (postingAmount p)))) updatedPostings
      
  let actualIntent = ActualEditIntent
        { intentDate = finishActualDate intent
        , intentDescription = transactionDescription txn
        , intentPostings = intentPostings
        , intentMetadata = [("plan-id", planIdText pId)]
        }
        
  actualPreview <- first (pure . FinishActualEditError) (prepareActualAppend actualSource actualIntent)
  
  let preview = PlanFinishPreview
        { finishCandidateBlock = candidateBlock actualPreview
        , finishCandidateCompleteSource = candidateCompleteSource actualPreview
        }
        
  _ <- first (pure . FinishCandidateParseError) (parseActualJournal (finishCandidateCompleteSource preview))
  
  pure preview
