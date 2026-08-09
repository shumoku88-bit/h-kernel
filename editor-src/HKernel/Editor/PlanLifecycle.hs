{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanAddPreview(..)
  , PlanAddError(..)
  , preparePlanAdd
  , preparePlanAddFromResolvedActualJournal
  , preparePlanAddFromResolvedJournals

  , PositivePlanEditAmount
  , PlanEditAmountError(..)
  , mkPositivePlanEditAmount
  , positivePlanEditAmountQuantity
  , PlanEditIntent(..)
  , PlanEditPreview(..)
  , PlanEditError(..)
  , preparePlanEdit
  , preparePlanEditFromResolvedActualJournal
  , preparePlanEditFromResolvedJournals

  , PositivePlanFinishAmount
  , PlanFinishAmountError(..)
  , mkPositivePlanFinishAmount
  , positivePlanFinishAmountQuantity
  , PlanFinishIntent(..)
  , PlanFinishPreview(..)
  , PlanFinishError(..)
  , preparePlanFinish
  , preparePlanFinishFromResolvedActualJournal
  ) where

import Data.Bifunctor (first)
import Data.Char (isAsciiLower, isAsciiUpper, isSpace, toLower)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Account (accountName)
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalCompletionDeclarations
  , actualJournalValue
  , admitActualJournalFromResolvedJournal
  , parseActualJournal
  )
import HKernel.Editor.ActualAppend
  ( ActualAppendPreview(..)
  , ActualEditError(..)
  , ActualEditIntent(..)
  , prepareActualAppendFromResolvedJournal
  )
import HKernel.Editor.SourceAppend (SourceBlock(..), appendSourceBlock)
import HKernel.Editor.TransactionBlock
  ( IntentPosting(..)
  , PreparedTransactionBlock(..)
  , TransactionBlockError
  , TransactionBlockIntent(..)
  , prepareTransactionBlock
  )
import HKernel.Journal
  ( Journal
  , appendJournalTransaction
  , journalAccountRegistry
  , replaceJournalTransactionAt
  )
import HKernel.Ledger
  ( Posting
  , Transaction
  , TransactionError
  , mkPosting
  , mkTransaction
  , postingAccount
  , postingAmount
  , transactionDate
  , transactionDescription
  , transactionPostings
  )
import HKernel.Money
  ( Quantity
  , amountCommodity
  , amountQuantity
  , commodityCode
  , mkAmount
  , negateQuantity
  , quantityToRational
  , renderQuantity
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
  ( IdentifiedPlanTransaction
  , PlanJournal
  , PlanJournalError
  , admitPlanJournalFromResolvedJournal
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
  planJ <- first (pure . AddPlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . AddActualJournalSyntaxError)
    (parseActualJournal actualSource)
  preparePlanAddFromJournals planJ planSource actualJ intent

preparePlanAddFromResolvedActualJournal
  :: Journal
  -> Text
  -> Text
  -> PlanAddIntent
  -> Either (NonEmpty PlanAddError) PlanAddPreview
preparePlanAddFromResolvedActualJournal resolvedActual planSource actualSource intent = do
  planJ <- first (pure . AddPlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . AddActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanAddFromJournals planJ planSource actualJ intent

-- | Prepare Plan Add from the same resolved Plan graph and root Plan text that
-- canonical path admission observes. Plan-owned metadata is admitted by
-- 'HKernel.Plan.Journal'; include-resolved accounting meaning stays in the
-- supplied Journal.
preparePlanAddFromResolvedJournals
  :: Journal
  -> Journal
  -> Text
  -> Text
  -> PlanAddIntent
  -> Either (NonEmpty PlanAddError) PlanAddPreview
preparePlanAddFromResolvedJournals resolvedPlan resolvedActual planSource actualSource intent = do
  planJ <- first (pure . AddPlanJournalSyntaxError)
    (admitPlanJournalFromResolvedJournal resolvedPlan planSource)
  actualJ <- first (pure . AddActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanAddFromJournals planJ planSource actualJ intent

preparePlanAddFromJournals
  :: PlanJournal
  -> Text
  -> ActualJournal
  -> PlanAddIntent
  -> Either (NonEmpty PlanAddError) PlanAddPreview
preparePlanAddFromJournals planJ planSource actualJ intent = do
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

  prepared <- first (pure . AddTransactionBlockError)
    (prepareTransactionBlock
      (journalAccountRegistry (planJournalValue planJ))
      blockIntent)

  let block = preparedTransactionBlock prepared
      candidateSource = appendSourceBlock planSource (SourceBlock block)
      candidateResolvedPlan = appendJournalTransaction
        (preparedTransaction prepared)
        (planJournalValue planJ)
      preview = PlanAddPreview
        { addCandidateBlock = block
        , addCandidateCompleteSource = candidateSource
        }

  _ <- first (pure . AddCandidateParseError)
    (admitPlanJournalFromResolvedJournal candidateResolvedPlan candidateSource)

  pure preview


-- Plan Edit

-- | Strictly positive replacement magnitude for a binary Plan edit.
-- The admitted posting signs remain the owner of direction.
newtype PositivePlanEditAmount = PositivePlanEditAmount
  { positivePlanEditAmountQuantity :: Quantity
  } deriving (Eq, Show)

data PlanEditAmountError
  = NonPositivePlanEditAmount Quantity
  deriving (Eq, Show)

mkPositivePlanEditAmount
  :: Quantity
  -> Either PlanEditAmountError PositivePlanEditAmount
mkPositivePlanEditAmount quantity
  | quantity <= zeroQuantity = Left (NonPositivePlanEditAmount quantity)
  | otherwise = Right (PositivePlanEditAmount quantity)

data PlanEditIntent = PlanEditIntent
  { editPlanId :: Text
  , editDate   :: Maybe Day
  , editAmount :: Maybe PositivePlanEditAmount
  } deriving (Eq, Show)

data PlanEditPreview = PlanEditPreview
  { editOriginalBlock           :: Text
  , editCandidateBlock          :: Text
  , editCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanEditError
  = EditPlanJournalSyntaxError (NonEmpty PlanJournalError)
  | EditActualJournalSyntaxError (NonEmpty ActualJournalError)
  | EditCandidateParseError (NonEmpty PlanJournalError)
  | EditCandidateTransactionError TransactionError
  | EditInvalidId PlanIdError
  | EditPlanNotFound PlanId
  | EditPlanAlreadyClosed PlanId
  | EditNoChange PlanId
  | EditAmountOnlyForBinaryPlan
  | EditAmountDirectionUnavailable
  | EditSourcePlanIdCoordinateMissing PlanId
  | EditSourcePlanIdCoordinateAmbiguous PlanId Int
  | EditSourceTransactionHeaderMissing PlanId
  | EditSourcePostingCoordinateMismatch Int Int
  | EditCandidateSemanticMismatch PlanId
  deriving (Eq, Show)

-- | Edit one open Plan by durable Plan identity while retaining source metadata
-- and unrelated comments verbatim.
--
-- The complete Plan and Actual sources are admitted first. Physical source
-- scanning then locates only the unique block already proven to own the target
-- @plan-id@. Date edits touch the transaction header date only. Amount edits
-- replace posting source lines in order while leaving metadata/comment lines in
-- place. The complete candidate is re-admitted before it can be published.
preparePlanEdit
  :: Text
  -> Text
  -> PlanEditIntent
  -> Either (NonEmpty PlanEditError) PlanEditPreview
preparePlanEdit planSource actualSource intent = do
  planJ <- first (pure . EditPlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . EditActualJournalSyntaxError)
    (parseActualJournal actualSource)
  preparePlanEditFromJournals planJ planSource actualJ intent

preparePlanEditFromResolvedActualJournal
  :: Journal
  -> Text
  -> Text
  -> PlanEditIntent
  -> Either (NonEmpty PlanEditError) PlanEditPreview
preparePlanEditFromResolvedActualJournal resolvedActual planSource actualSource intent = do
  planJ <- first (pure . EditPlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . EditActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanEditFromJournals planJ planSource actualJ intent

-- | Prepare Plan Edit from include-resolved Plan and Actual Journals while root
-- Plan text remains the owner of physical Plan metadata/source placement.
preparePlanEditFromResolvedJournals
  :: Journal
  -> Journal
  -> Text
  -> Text
  -> PlanEditIntent
  -> Either (NonEmpty PlanEditError) PlanEditPreview
preparePlanEditFromResolvedJournals resolvedPlan resolvedActual planSource actualSource intent = do
  planJ <- first (pure . EditPlanJournalSyntaxError)
    (admitPlanJournalFromResolvedJournal resolvedPlan planSource)
  actualJ <- first (pure . EditActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanEditFromJournals planJ planSource actualJ intent

preparePlanEditFromJournals
  :: PlanJournal
  -> Text
  -> ActualJournal
  -> PlanEditIntent
  -> Either (NonEmpty PlanEditError) PlanEditPreview
preparePlanEditFromJournals planJ planSource actualJ intent = do
  pId <- first (pure . EditInvalidId) (mkPlanId (editPlanId intent))

  (targetIndex, identified) <- case filter ((== pId) . identifiedPlanId . snd)
      (zip [0..] (planJournalTransactions planJ)) of
    [] -> Left (pure (EditPlanNotFound pId))
    [value] -> Right value
    values -> Left (pure (EditSourcePlanIdCoordinateAmbiguous pId (length values)))

  if pId `elem` map declaredCompletionPlanId
      (actualJournalCompletionDeclarations actualJ)
    then Left (pure (EditPlanAlreadyClosed pId))
    else Right ()

  let transaction = identifiedPlanTransaction identified
      originalPostings = transactionPostings transaction
      targetDate = maybe (transactionDate transaction) id (editDate intent)

  updatedPostings <- editPlanPostings (editAmount intent) originalPostings
  let dateChanged = targetDate /= transactionDate transaction
      amountChanged = updatedPostings /= originalPostings
  if not dateChanged && not amountChanged
    then Left (pure (EditNoChange pId))
    else Right ()

  located <- first pure (locatePlanSourceBlock pId transaction planSource)
  editedBlockLines <- first pure
    (editLocatedPlanBlock pId targetDate (editAmount intent) updatedPostings located)

  let originalBlock = T.intercalate "\n" (locatedBlockLines located)
      candidateBlock = T.intercalate "\n" editedBlockLines
      candidateSource = T.intercalate "\n"
        (locatedPrefixLines located ++ editedBlockLines ++ locatedSuffixLines located)
      preview = PlanEditPreview
        { editOriginalBlock = originalBlock
        , editCandidateBlock = candidateBlock
        , editCandidateCompleteSource = candidateSource
        }

  candidateTransaction <- first (pure . EditCandidateTransactionError)
    (mkTransaction
      targetDate
      (transactionDescription transaction)
      updatedPostings)
  candidateResolvedPlan <- case replaceJournalTransactionAt
      targetIndex
      candidateTransaction
      (planJournalValue planJ) of
    Just journal -> Right journal
    Nothing -> Left (pure (EditCandidateSemanticMismatch pId))
  candidateJournal <- first (pure . EditCandidateParseError)
    (admitPlanJournalFromResolvedJournal candidateResolvedPlan candidateSource)
  candidateTarget <- case filter ((== pId) . identifiedPlanId)
      (planJournalTransactions candidateJournal) of
    [value] -> Right (identifiedPlanTransaction value)
    _ -> Left (pure (EditCandidateSemanticMismatch pId))

  if transactionDate candidateTarget == targetDate
      && transactionDescription candidateTarget == transactionDescription transaction
      && transactionPostings candidateTarget == updatedPostings
    then Right preview
    else Left (pure (EditCandidateSemanticMismatch pId))

editPlanPostings
  :: Maybe PositivePlanEditAmount
  -> NonEmpty Posting
  -> Either (NonEmpty PlanEditError) (NonEmpty Posting)
editPlanPostings Nothing postings = Right postings
editPlanPostings (Just positiveAmount) postings
  | length postings /= 2 = Left (pure EditAmountOnlyForBinaryPlan)
  | any ((== zeroQuantity) . amountQuantity . postingAmount)
      (NonEmpty.toList postings) = Left (pure EditAmountDirectionUnavailable)
  | otherwise = Right (fmap replaceAmount postings)
  where
    newMagnitude = positivePlanEditAmountQuantity positiveAmount
    replaceAmount posting =
      let oldQuantity = amountQuantity (postingAmount posting)
          newQuantity
            | quantityToRational oldQuantity < 0 = negateQuantity newMagnitude
            | otherwise = newMagnitude
      in mkPosting
          (postingAccount posting)
          (mkAmount (amountCommodity (postingAmount posting)) newQuantity)

data LocatedPlanBlock = LocatedPlanBlock
  { locatedPrefixLines :: [Text]
  , locatedBlockLines  :: [Text]
  , locatedSuffixLines :: [Text]
  }

locatePlanSourceBlock
  :: PlanId
  -> Transaction
  -> Text
  -> Either PlanEditError LocatedPlanBlock
locatePlanSourceBlock pId transaction source =
  case planIdCoordinates of
    [] -> Left (EditSourcePlanIdCoordinateMissing pId)
    [metadataIndex] -> do
      start <- case reverse
          [ index
          | (index, line) <- zip [0..metadataIndex] sourceLines
          , isTopLevelSourceLine line
          ] of
        firstStart : _ -> Right firstStart
        [] -> Left (EditSourceTransactionHeaderMissing pId)
      let header = sourceLines !! start
          expectedDatePrefix = renderDay (transactionDate transaction)
      if not (expectedDatePrefix `T.isPrefixOf` header)
        then Left (EditSourceTransactionHeaderMissing pId)
        else
          let endExclusive = case listToMaybe
                  [ index
                  | (index, line) <- zip [0..] sourceLines
                  , index > start
                  , isTopLevelSourceLine line
                  ] of
                Just index -> index
                Nothing -> length sourceLines
          in Right LocatedPlanBlock
              { locatedPrefixLines = take start sourceLines
              , locatedBlockLines = take (endExclusive - start)
                  (drop start sourceLines)
              , locatedSuffixLines = drop endExclusive sourceLines
              }
    coordinates -> Left
      (EditSourcePlanIdCoordinateAmbiguous pId (length coordinates))
  where
    sourceLines = T.splitOn "\n" source
    planIdCoordinates =
      [ index
      | (index, line) <- zip [0..] sourceLines
      , metadataPlanId line == Just (planIdText pId)
      ]

metadataPlanId :: Text -> Maybe Text
metadataPlanId line
  | not (isIndentedSourceLine line && isCommentSourceLine line) = Nothing
  | otherwise =
      let strippedComment = T.dropWhile
            (\character -> character == ';' || isSpace character)
            (T.strip line)
          (rawKey, remainder) = T.breakOn ":" strippedComment
          key = T.toCaseFold (T.strip rawKey)
      in if key == "plan-id" && not (T.null remainder)
          then Just (T.strip (T.drop 1 remainder))
          else Nothing

isTopLevelSourceLine :: Text -> Bool
isTopLevelSourceLine line =
  not (T.null (T.strip line))
    && not (isIndentedSourceLine line)
    && not (isCommentSourceLine line)

isIndentedSourceLine :: Text -> Bool
isIndentedSourceLine line = case T.uncons line of
  Just (character, _) -> isSpace character
  Nothing -> False

isCommentSourceLine :: Text -> Bool
isCommentSourceLine line =
  ";" `T.isPrefixOf` T.stripStart line
    || "#" `T.isPrefixOf` T.stripStart line

editLocatedPlanBlock
  :: PlanId
  -> Day
  -> Maybe PositivePlanEditAmount
  -> NonEmpty Posting
  -> LocatedPlanBlock
  -> Either PlanEditError [Text]
editLocatedPlanBlock pId targetDate amountEdit postings located =
  case locatedBlockLines located of
    [] -> Left (EditSourceTransactionHeaderMissing pId)
    header : rest -> do
      updatedRest <- case amountEdit of
        Nothing -> Right rest
        Just _ -> replacePostingSourceLines
          rest
          (map renderPostingLine (NonEmpty.toList postings))
      pure (replaceHeaderDate targetDate header : updatedRest)

replaceHeaderDate :: Day -> Text -> Text
replaceHeaderDate day header = renderDay day <> T.drop 10 header

replacePostingSourceLines
  :: [Text]
  -> [Text]
  -> Either PlanEditError [Text]
replacePostingSourceLines sourceLines replacements = go sourceLines replacements 0
  where
    expectedCount = length replacements

    go [] [] _ = Right []
    go [] remaining replaced = Left
      (EditSourcePostingCoordinateMismatch expectedCount
        (replaced + expectedCount - length remaining))
    go (line : lines) remaining replaced
      | isPostingSourceLine line = case remaining of
          replacement : rest ->
            (replacement :) <$> go lines rest (replaced + 1)
          [] -> Left
            (EditSourcePostingCoordinateMismatch expectedCount (replaced + 1))
      | otherwise = (line :) <$> go lines remaining replaced

isPostingSourceLine :: Text -> Bool
isPostingSourceLine line =
  isIndentedSourceLine line
    && not (T.null stripped)
    && not (isCommentSourceLine line)
  where
    stripped = T.strip line

renderPostingLine :: Posting -> Text
renderPostingLine posting =
  "    " <> accountName (postingAccount posting)
    <> "    " <> renderQuantity (amountQuantity amount)
    <> " " <> commodityCode (amountCommodity amount)
  where
    amount = postingAmount posting

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%F"


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
  actualJ <- first (pure . FinishActualJournalSyntaxError)
    (parseActualJournal actualSource)
  preparePlanFinishFromJournals planSource actualSource actualJ intent

preparePlanFinishFromResolvedActualJournal
  :: Journal
  -> Text
  -> Text
  -> PlanFinishIntent
  -> Either (NonEmpty PlanFinishError) PlanFinishPreview
preparePlanFinishFromResolvedActualJournal resolvedActual planSource actualSource intent = do
  actualJ <- first (pure . FinishActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanFinishFromJournals planSource actualSource actualJ intent

preparePlanFinishFromJournals
  :: Text
  -> Text
  -> ActualJournal
  -> PlanFinishIntent
  -> Either (NonEmpty PlanFinishError) PlanFinishPreview
preparePlanFinishFromJournals planSource actualSource actualJ intent = do
  planJ <- first (pure . FinishPlanJournalSyntaxError) (parsePlanJournal planSource)

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

  let intentPostings = fmap (\p -> IntentPosting (postingAccount p) (amountQuantity (postingAmount p)) (Just (amountCommodity (postingAmount p)))) updatedPostings

  let actualIntent = ActualEditIntent
        { intentDate = finishActualDate intent
        , intentDescription = transactionDescription txn
        , intentPostings = intentPostings
        , intentMetadata = [("plan-id", planIdText pId)]
        }

  actualPreview <- first (pure . FinishActualEditError)
    (prepareActualAppendFromResolvedJournal
      (actualJournalValue actualJ)
      actualSource
      actualIntent)

  let preview = PlanFinishPreview
        { finishCandidateBlock = candidateBlock actualPreview
        , finishCandidateCompleteSource = candidateCompleteSource actualPreview
        }

  pure preview
