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
  ) where

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalCompletionDeclarations
  , admitActualJournalFromResolvedJournal
  , parseActualJournal
  )
import HKernel.Editor.PlanIdentity
  ( descriptionPlanIdStem
  , generateAvailablePlanId
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
  , JournalPostingSource
  , appendJournalTransaction
  , journalAccountRegistry
  , journalPostingSourceLine
  , journalPostingSourceQuantityColumns
  , journalTransactionSourceHeaderLine
  , journalTransactionSourceLastLine
  , journalTransactionSourcePostings
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
  , planJournalTransactionSourceFor
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
      (generateAvailablePlanId
        (T.pack (formatTime defaultTimeLocale "%Y-%m-%d" (addDate intent)))
        (case addSeries intent of
          Just series -> series
          Nothing -> descriptionPlanIdStem (addDescription intent))
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
  | EditSourcePostingQuantityCoordinateInvalid Int
  | EditCandidateSemanticMismatch PlanId
  deriving (Eq, Show)

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

  located <- first pure (locatePlanSourceBlock planJ pId transaction planSource)
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
    (mkTransaction targetDate (transactionDescription transaction) updatedPostings)
  candidateResolvedPlan <- case replaceJournalTransactionAt
      targetIndex candidateTransaction (planJournalValue planJ) of
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
  { locatedPrefixLines    :: [Text]
  , locatedBlockLines     :: [Text]
  , locatedSuffixLines    :: [Text]
  , locatedHeaderLine     :: Int
  , locatedPostingSources :: [JournalPostingSource]
  }

locatePlanSourceBlock
  :: PlanJournal
  -> PlanId
  -> Transaction
  -> Text
  -> Either PlanEditError LocatedPlanBlock
locatePlanSourceBlock planJ pId transaction source = do
  sourceEvidence <- case planJournalTransactionSourceFor pId planJ of
    Nothing -> Left (EditSourcePlanIdCoordinateMissing pId)
    Just value -> Right value

  let sourceLines = T.splitOn "\n" source
      headerLine = journalTransactionSourceHeaderLine sourceEvidence
      lastLine = journalTransactionSourceLastLine sourceEvidence
      postingSources = journalTransactionSourcePostings sourceEvidence
      start = headerLine - 1
      endExclusive = lastLine
      blockLength = endExclusive - start
      postingIndexes = map
        (\postingSource -> journalPostingSourceLine postingSource - headerLine)
        postingSources
      expectedPostingCount = NonEmpty.length (transactionPostings transaction)
      validPostingIndexes = filter
        (\index -> index > 0 && index < blockLength)
        postingIndexes

  if start < 0
      || endExclusive <= start
      || endExclusive > length sourceLines
    then Left (EditSourceTransactionHeaderMissing pId)
    else Right ()

  if length postingSources /= expectedPostingCount
      || length validPostingIndexes /= expectedPostingCount
    then Left
      (EditSourcePostingCoordinateMismatch
        expectedPostingCount
        (length validPostingIndexes))
    else Right ()

  let header = sourceLines !! start
      expectedDatePrefix = renderDay (transactionDate transaction)
  if not (expectedDatePrefix `T.isPrefixOf` header)
    then Left (EditSourceTransactionHeaderMissing pId)
    else Right LocatedPlanBlock
      { locatedPrefixLines = take start sourceLines
      , locatedBlockLines = take blockLength (drop start sourceLines)
      , locatedSuffixLines = drop endExclusive sourceLines
      , locatedHeaderLine = headerLine
      , locatedPostingSources = postingSources
      }

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
      let datedLines = replaceHeaderDate targetDate header : rest
      case amountEdit of
        Nothing -> Right datedLines
        Just _ -> replacePostingQuantities
          (locatedHeaderLine located)
          (locatedPostingSources located)
          datedLines
          (map (renderQuantity . amountQuantity . postingAmount)
            (NonEmpty.toList postings))

replaceHeaderDate :: Day -> Text -> Text
replaceHeaderDate day header = renderDay day <> T.drop 10 header

replacePostingQuantities
  :: Int
  -> [JournalPostingSource]
  -> [Text]
  -> [Text]
  -> Either PlanEditError [Text]
replacePostingQuantities headerLine postingSources sourceLines replacements
  | length postingSources /= expectedCount = Left
      (EditSourcePostingCoordinateMismatch expectedCount (length postingSources))
  | length validIndexes /= expectedCount = Left
      (EditSourcePostingCoordinateMismatch expectedCount (length validIndexes))
  | otherwise = do
      replacementLines <- traverse replacementAt (zip postingSources replacements)
      let replacementsByIndex = [entry | Just entry <- replacementLines]
      pure
        [ maybe line id (lookup index replacementsByIndex)
        | (index, line) <- zip [0..] sourceLines
        ]
  where
    expectedCount = length replacements
    postingIndex postingSource = journalPostingSourceLine postingSource - headerLine
    validIndexes = filter
      (\index -> index > 0 && index < length sourceLines)
      (map postingIndex postingSources)

    replacementAt (postingSource, replacement) =
      case journalPostingSourceQuantityColumns postingSource of
        Nothing -> Right Nothing
        Just columns -> do
          let index = postingIndex postingSource
              sourceLine = sourceLines !! index
          edited <- replaceQuantityToken
            (journalPostingSourceLine postingSource)
            columns
            replacement
            sourceLine
          Right (Just (index, edited))

replaceQuantityToken
  :: Int
  -> (Int, Int)
  -> Text
  -> Text
  -> Either PlanEditError Text
replaceQuantityToken lineNumber (start, end) replacement sourceLine
  | start < 0 || end <= start || end > T.length sourceLine =
      Left (EditSourcePostingQuantityCoordinateInvalid lineNumber)
  | otherwise = Right
      (T.take start sourceLine <> replacement <> T.drop end sourceLine)

renderDay :: Day -> Text
renderDay = T.pack . formatTime defaultTimeLocale "%F"
