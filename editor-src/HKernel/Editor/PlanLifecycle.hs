{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.PlanLifecycle
  ( PlanAddIntent(..)
  , PlanAddPreview(..)
  , PlanAddError(..)
  , preparePlanAdd
  , preparePlanAddFromResolvedActualJournal
  , preparePlanAddFromResolvedJournals

  , PlanCancelIntent(..)
  , PlanCancelPreview(..)
  , PlanSupersedeIntent(..)
  , PlanSupersedePreview(..)
  , PlanRetirementWriteError(..)
  , planClosedIds
  , planInactiveIdsAt
  , preparePlanCancel
  , preparePlanCancelFromResolvedActualJournal
  , preparePlanCancelFromResolvedJournals
  , preparePlanSupersede
  , preparePlanSupersedeFromResolvedActualJournal
  , preparePlanSupersedeFromResolvedJournals

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
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)

import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , actualJournalCompletionDeclarations
  , actualJournalIdentifiedTransactions
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
  , JournalMetadata
  , JournalPostingSource
  , appendJournalTransaction
  , journalAccountRegistry
  , journalMetadataKey
  , journalMetadataLine
  , journalPostingSourceLine
  , journalPostingSourceQuantityColumns
  , journalTransactionSourceHeaderLine
  , journalTransactionSourceLastLine
  , journalTransactionSourceMetadata
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
  , PlanRetirement
  , mkPlanId
  , planIdText
  , planRetiredOn
  , planRetirementSuccessor
  , retiredPlanId
  )
import HKernel.Plan.Completion
  ( declaredCompletionActualId
  , declaredCompletionPlanId
  , identifiedActualId
  , identifiedActualTransaction
  )
import HKernel.Plan.Journal
  ( IdentifiedPlanTransaction
  , PlanJournal
  , PlanJournalError
  , PlanLifecycleError
  , admitPlanJournalFromResolvedJournal
  , admitPlanRetirements
  , identifiedPlanId
  , identifiedPlanTransaction
  , parsePlanJournal
  , planJournalTransactionSourceFor
  , planJournalTransactions
  , planJournalValue
  , retiredPlanIdsAt
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

data PreparedPlanAdd = PreparedPlanAdd
  { preparedPlanAddId          :: PlanId
  , preparedPlanAddTransaction :: Transaction
  , preparedPlanAddPreview     :: PlanAddPreview
  }

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
preparePlanAddFromJournals planJ planSource actualJ intent =
  preparedPlanAddPreview <$> preparePlanAddCandidateFromJournals
    planJ planSource actualJ intent

preparePlanAddCandidateFromJournals
  :: PlanJournal
  -> Text
  -> ActualJournal
  -> PlanAddIntent
  -> Either (NonEmpty PlanAddError) PreparedPlanAdd
preparePlanAddCandidateFromJournals planJ planSource actualJ intent = do
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
      transaction = preparedTransaction prepared
      candidateSource = appendSourceBlock planSource (SourceBlock block)
      candidateResolvedPlan = appendJournalTransaction
        transaction
        (planJournalValue planJ)
      preview = PlanAddPreview
        { addCandidateBlock = block
        , addCandidateCompleteSource = candidateSource
        }

  _ <- first (pure . AddCandidateParseError)
    (admitPlanJournalFromResolvedJournal candidateResolvedPlan candidateSource)

  pure PreparedPlanAdd
    { preparedPlanAddId = newPlanId
    , preparedPlanAddTransaction = transaction
    , preparedPlanAddPreview = preview
    }

-- Plan cancellation / supersession

data PlanCancelIntent = PlanCancelIntent
  { cancelPlanId :: Text
  , cancelOn     :: Day
  } deriving (Eq, Show)

data PlanCancelPreview = PlanCancelPreview
  { cancelOriginalBlock           :: Text
  , cancelRetiredBlock            :: Text
  , cancelCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanSupersedeIntent = PlanSupersedeIntent
  { supersedePlanId       :: Text
  , supersedeOn           :: Day
  , supersedeReplacement  :: PlanAddIntent
  } deriving (Eq, Show)

data PlanSupersedePreview = PlanSupersedePreview
  { supersedeOriginalBlock           :: Text
  , supersedeRetiredBlock            :: Text
  , supersedeReplacementBlock        :: Text
  , supersedeReplacementPlanId       :: PlanId
  , supersedeCandidateCompleteSource :: Text
  } deriving (Eq, Show)

data PlanRetirementWriteError
  = RetirePlanJournalSyntaxError (NonEmpty PlanJournalError)
  | RetireActualJournalSyntaxError (NonEmpty ActualJournalError)
  | RetireLifecycleAdmissionError (NonEmpty PlanLifecycleError)
  | RetireReplacementAddError PlanAddError
  | RetireInvalidId PlanIdError
  | RetirePlanNotFound PlanId
  | RetirePlanAlreadyCompleted PlanId
  | RetirePlanAlreadyRetired PlanId
  | RetireSourceEvidenceMissing PlanId
  | RetireSourcePlanIdMetadataMissing PlanId
  | RetireSourcePlanIdMetadataAmbiguous PlanId Int
  | RetireSourceCoordinateInvalid PlanId
  | RetireCandidateParseError (NonEmpty PlanJournalError)
  | RetireCandidateLifecycleError (NonEmpty PlanLifecycleError)
  | RetireCandidateSemanticMismatch PlanId
  deriving (Eq, Show)

-- | Plans that already carry durable closure evidence and therefore must not
-- receive another lifecycle-changing mutation. Completion and retirement are
-- different kinds of evidence, but both close the selected Plan to further
-- Edit / Complete / retirement operations.
planClosedIds
  :: PlanJournal
  -> ActualJournal
  -> Either (NonEmpty PlanLifecycleError) (Set.Set PlanId)
planClosedIds planJ actualJ = do
  retirements <- admitPlanRetirements planJ
  let completed = Set.fromList
        (map declaredCompletionPlanId
          (actualJournalCompletionDeclarations actualJ))
      retired = Set.fromList (map retiredPlanId retirements)
  pure (Set.union completed retired)

-- | Plans inactive at one observation day. Retirement dates remain temporal:
-- future retirement evidence keeps the Plan visible before its effective day.
-- Completion is likewise compared with the date of the Actual carrying the
-- admitted completion declaration instead of being projected backward in time.
planInactiveIdsAt
  :: Day
  -> PlanJournal
  -> ActualJournal
  -> Either (NonEmpty PlanLifecycleError) (Set.Set PlanId)
planInactiveIdsAt observation planJ actualJ = do
  retirements <- admitPlanRetirements planJ
  let completed = Set.fromList
        [ declaredCompletionPlanId declaration
        | declaration <- actualJournalCompletionDeclarations actualJ
        , any (completionOccurredBy declaration)
            (actualJournalIdentifiedTransactions actualJ)
        ]
      retired = retiredPlanIdsAt observation retirements
  pure (Set.union completed retired)
  where
    completionOccurredBy declaration actual =
      identifiedActualId actual == declaredCompletionActualId declaration
        && transactionDate (identifiedActualTransaction actual) <= observation

preparePlanCancel
  :: Text
  -> Text
  -> PlanCancelIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanCancelPreview
preparePlanCancel planSource actualSource intent = do
  planJ <- first (pure . RetirePlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . RetireActualJournalSyntaxError)
    (parseActualJournal actualSource)
  preparePlanCancelFromJournals planJ planSource actualJ intent

preparePlanCancelFromResolvedActualJournal
  :: Journal
  -> Text
  -> Text
  -> PlanCancelIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanCancelPreview
preparePlanCancelFromResolvedActualJournal resolvedActual planSource actualSource intent = do
  planJ <- first (pure . RetirePlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . RetireActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanCancelFromJournals planJ planSource actualJ intent

preparePlanCancelFromResolvedJournals
  :: Journal
  -> Journal
  -> Text
  -> Text
  -> PlanCancelIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanCancelPreview
preparePlanCancelFromResolvedJournals resolvedPlan resolvedActual planSource actualSource intent = do
  planJ <- first (pure . RetirePlanJournalSyntaxError)
    (admitPlanJournalFromResolvedJournal resolvedPlan planSource)
  actualJ <- first (pure . RetireActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanCancelFromJournals planJ planSource actualJ intent

preparePlanSupersede
  :: Text
  -> Text
  -> PlanSupersedeIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanSupersedePreview
preparePlanSupersede planSource actualSource intent = do
  planJ <- first (pure . RetirePlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . RetireActualJournalSyntaxError)
    (parseActualJournal actualSource)
  preparePlanSupersedeFromJournals planJ planSource actualJ intent

preparePlanSupersedeFromResolvedActualJournal
  :: Journal
  -> Text
  -> Text
  -> PlanSupersedeIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanSupersedePreview
preparePlanSupersedeFromResolvedActualJournal resolvedActual planSource actualSource intent = do
  planJ <- first (pure . RetirePlanJournalSyntaxError)
    (parsePlanJournal planSource)
  actualJ <- first (pure . RetireActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanSupersedeFromJournals planJ planSource actualJ intent

preparePlanSupersedeFromResolvedJournals
  :: Journal
  -> Journal
  -> Text
  -> Text
  -> PlanSupersedeIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanSupersedePreview
preparePlanSupersedeFromResolvedJournals resolvedPlan resolvedActual planSource actualSource intent = do
  planJ <- first (pure . RetirePlanJournalSyntaxError)
    (admitPlanJournalFromResolvedJournal resolvedPlan planSource)
  actualJ <- first (pure . RetireActualJournalSyntaxError)
    (admitActualJournalFromResolvedJournal resolvedActual actualSource)
  preparePlanSupersedeFromJournals planJ planSource actualJ intent

preparePlanCancelFromJournals
  :: PlanJournal
  -> Text
  -> ActualJournal
  -> PlanCancelIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanCancelPreview
preparePlanCancelFromJournals planJ planSource actualJ intent = do
  (pId, target, existingRetirements) <-
    prepareRetirementTarget planJ actualJ (cancelPlanId intent)
  sourceEdit <- first pure
    (insertPlanLifecycleMetadata
      planJ
      pId
      planSource
      [("cancelled-on", renderDay (cancelOn intent))])
  candidateJournal <- first (pure . RetireCandidateParseError)
    (admitPlanJournalFromResolvedJournal
      (planJournalValue planJ)
      (retirementCandidateSource sourceEdit))
  candidateRetirements <- first (pure . RetireCandidateLifecycleError)
    (admitPlanRetirements candidateJournal)

  validateRetirementCandidate
    pId
    target
    existingRetirements
    (cancelOn intent)
    Nothing
    (planJournalTransactions planJ)
    (planJournalTransactions candidateJournal)
    candidateRetirements

  pure PlanCancelPreview
    { cancelOriginalBlock = retirementOriginalBlock sourceEdit
    , cancelRetiredBlock = retirementEditedBlock sourceEdit
    , cancelCandidateCompleteSource = retirementCandidateSource sourceEdit
    }

preparePlanSupersedeFromJournals
  :: PlanJournal
  -> Text
  -> ActualJournal
  -> PlanSupersedeIntent
  -> Either (NonEmpty PlanRetirementWriteError) PlanSupersedePreview
preparePlanSupersedeFromJournals planJ planSource actualJ intent = do
  (pId, target, existingRetirements) <-
    prepareRetirementTarget planJ actualJ (supersedePlanId intent)
  preparedAdd <- first (fmap RetireReplacementAddError)
    (preparePlanAddCandidateFromJournals
      planJ planSource actualJ (supersedeReplacement intent))
  let successorId = preparedPlanAddId preparedAdd
      successorTransaction = preparedPlanAddTransaction preparedAdd
      addPreview = preparedPlanAddPreview preparedAdd
  sourceEdit <- first pure
    (insertPlanLifecycleMetadata
      planJ
      pId
      planSource
      [ ("superseded-on", renderDay (supersedeOn intent))
      , ("superseded-by", planIdText successorId)
      ])
  let candidateSource = appendSourceBlock
        (retirementCandidateSource sourceEdit)
        (SourceBlock (addCandidateBlock addPreview))
      candidateResolvedPlan = appendJournalTransaction
        successorTransaction
        (planJournalValue planJ)
  candidateJournal <- first (pure . RetireCandidateParseError)
    (admitPlanJournalFromResolvedJournal candidateResolvedPlan candidateSource)
  candidateRetirements <- first (pure . RetireCandidateLifecycleError)
    (admitPlanRetirements candidateJournal)

  validateRetirementCandidate
    pId
    target
    existingRetirements
    (supersedeOn intent)
    (Just successorId)
    (planJournalTransactions planJ)
    (planJournalTransactions candidateJournal)
    candidateRetirements

  let candidateIds = map identifiedPlanId (planJournalTransactions candidateJournal)
      originalIds = map identifiedPlanId (planJournalTransactions planJ)
      candidateTransactions =
        map identifiedPlanTransaction (planJournalTransactions candidateJournal)
      originalTransactions =
        map identifiedPlanTransaction (planJournalTransactions planJ)
  if candidateIds == originalIds ++ [successorId]
      && candidateTransactions == originalTransactions ++ [successorTransaction]
      && retirementEvidencePresent
          pId (supersedeOn intent) (Just successorId) candidateRetirements
    then Right PlanSupersedePreview
      { supersedeOriginalBlock = retirementOriginalBlock sourceEdit
      , supersedeRetiredBlock = retirementEditedBlock sourceEdit
      , supersedeReplacementBlock = addCandidateBlock addPreview
      , supersedeReplacementPlanId = successorId
      , supersedeCandidateCompleteSource = candidateSource
      }
    else Left (pure (RetireCandidateSemanticMismatch pId))

prepareRetirementTarget
  :: PlanJournal
  -> ActualJournal
  -> Text
  -> Either
      (NonEmpty PlanRetirementWriteError)
      (PlanId, IdentifiedPlanTransaction, [PlanRetirement])
prepareRetirementTarget planJ actualJ rawPlanId = do
  pId <- first (pure . RetireInvalidId) (mkPlanId rawPlanId)
  target <- case filter ((== pId) . identifiedPlanId)
      (planJournalTransactions planJ) of
    [] -> Left (pure (RetirePlanNotFound pId))
    [value] -> Right value
    _ -> Left (pure (RetireCandidateSemanticMismatch pId))
  retirements <- first (pure . RetireLifecycleAdmissionError)
    (admitPlanRetirements planJ)
  if any ((== pId) . retiredPlanId) retirements
    then Left (pure (RetirePlanAlreadyRetired pId))
    else Right ()
  if pId `elem` map declaredCompletionPlanId
      (actualJournalCompletionDeclarations actualJ)
    then Left (pure (RetirePlanAlreadyCompleted pId))
    else Right ()
  pure (pId, target, retirements)

data RetirementSourceEdit = RetirementSourceEdit
  { retirementOriginalBlock   :: Text
  , retirementEditedBlock     :: Text
  , retirementCandidateSource :: Text
  }

insertPlanLifecycleMetadata
  :: PlanJournal
  -> PlanId
  -> Text
  -> [(Text, Text)]
  -> Either PlanRetirementWriteError RetirementSourceEdit
insertPlanLifecycleMetadata planJ pId source additions = do
  sourceEvidence <- maybe
    (Left (RetireSourceEvidenceMissing pId))
    Right
    (planJournalTransactionSourceFor pId planJ)
  planIdMetadata <- case filter ((== "plan-id") . journalMetadataKey)
      (journalTransactionSourceMetadata sourceEvidence) of
    [] -> Left (RetireSourcePlanIdMetadataMissing pId)
    [entry] -> Right entry
    entries -> Left (RetireSourcePlanIdMetadataAmbiguous pId (length entries))

  let sourceLines = T.splitOn "\n" source
      headerLine = journalTransactionSourceHeaderLine sourceEvidence
      lastLine = journalTransactionSourceLastLine sourceEvidence
      start = headerLine - 1
      endExclusive = lastLine
      blockLength = endExclusive - start
      planIdLine = journalMetadataLine planIdMetadata
      insertIndex = planIdLine - headerLine + 1

  if start < 0
      || endExclusive <= start
      || endExclusive > length sourceLines
      || planIdLine < headerLine
      || planIdLine > lastLine
      || insertIndex <= 0
      || insertIndex > blockLength
    then Left (RetireSourceCoordinateInvalid pId)
    else Right ()

  let blockLines = take blockLength (drop start sourceLines)
      metadataSourceLine = sourceLines !! (planIdLine - 1)
      indentation = T.takeWhile (\c -> c == ' ' || c == '\t') metadataSourceLine
      renderedAdditions =
        [ indentation <> "; " <> key <> ": " <> value
        | (key, value) <- additions
        ]
      editedBlockLines =
        take insertIndex blockLines
          ++ renderedAdditions
          ++ drop insertIndex blockLines
      candidateLines =
        take start sourceLines
          ++ editedBlockLines
          ++ drop endExclusive sourceLines

  pure RetirementSourceEdit
    { retirementOriginalBlock = T.intercalate "\n" blockLines
    , retirementEditedBlock = T.intercalate "\n" editedBlockLines
    , retirementCandidateSource = T.intercalate "\n" candidateLines
    }

validateRetirementCandidate
  :: PlanId
  -> IdentifiedPlanTransaction
  -> [PlanRetirement]
  -> Day
  -> Maybe PlanId
  -> [IdentifiedPlanTransaction]
  -> [IdentifiedPlanTransaction]
  -> [PlanRetirement]
  -> Either (NonEmpty PlanRetirementWriteError) ()
validateRetirementCandidate pId target existingRetirements retiredOn successor originalPlans candidatePlans candidateRetirements = do
  let originalIds = map identifiedPlanId originalPlans
      candidatePrefix = take (length originalPlans) candidatePlans
      candidateTarget = filter ((== pId) . identifiedPlanId) candidatePlans
  if map identifiedPlanId candidatePrefix == originalIds
      && map identifiedPlanTransaction candidatePrefix
        == map identifiedPlanTransaction originalPlans
      && case candidateTarget of
        [value] -> identifiedPlanTransaction value == identifiedPlanTransaction target
        _ -> False
    then Right ()
    else Left (pure (RetireCandidateSemanticMismatch pId))
  if all (`elem` candidateRetirements) existingRetirements
      && length candidateRetirements == length existingRetirements + 1
      && retirementEvidencePresent pId retiredOn successor candidateRetirements
    then Right ()
    else Left (pure (RetireCandidateSemanticMismatch pId))

retirementEvidencePresent
  :: PlanId
  -> Day
  -> Maybe PlanId
  -> [PlanRetirement]
  -> Bool
retirementEvidencePresent pId retiredOn successor retirements =
  case filter ((== pId) . retiredPlanId) retirements of
    [retirement] ->
      planRetiredOn retirement == retiredOn
        && planRetirementSuccessor retirement == successor
    _ -> False

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
  | EditPlanLifecycleError (NonEmpty PlanLifecycleError)
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

  closedIds <- first (pure . EditPlanLifecycleError)
    (planClosedIds planJ actualJ)
  if pId `Set.member` closedIds
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