-- | Pure projection and selected-entry operations for the Actual transaction
-- workspace.
--
-- Delivery adapters choose how an Account or transaction is selected and how
-- transactions are presented. Ordinary recording does not require durable
-- identity. Identity promotion is an optional after-the-fact operation for a
-- selected admitted entry when another Household fact needs a durable target.
module HKernel.Editor.ActualWorkspace
  ( transactionEntriesForAccount
  , newestTransactionEntriesForAccount
  , ActualIdentityPromotionError(..)
  , ActualIdentityPromotionPreview(..)
  , prepareActualIdentityPromotion
  ) where

import Data.Bifunctor (first)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Account (Account)
import HKernel.Actual.Journal
  ( ActualJournal
  , ActualJournalError
  , ActualTransactionEntry
  , actualJournalIdentifiedTransactions
  , actualJournalTransactionEntries
  , actualJournalValue
  , actualTransactionEntryIdentity
  , actualTransactionEntrySource
  , actualTransactionEntryTransaction
  , admitActualJournalFromResolvedSources
  )
import HKernel.Journal
  ( JournalError
  , JournalTransactionSource
  , journalDocumentTransactionSources
  , journalTransactionSourceHeaderLine
  , parseJournalDocument
  )
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , transactionPostings
  )
import HKernel.Plan.Completion
  ( ActualTransactionId
  , actualTransactionIdText
  , identifiedActualId
  )

transactionEntriesForAccount
  :: Maybe Account
  -> [ActualTransactionEntry]
  -> [ActualTransactionEntry]
transactionEntriesForAccount Nothing = id
transactionEntriesForAccount (Just selectedAccount) =
  filter
    (transactionMatchesAccount selectedAccount
      . actualTransactionEntryTransaction)

-- | Present admitted Actual entries newest-first without changing canonical
-- source order. Account filtering and selected-entry lookup must both use this
-- same projection.
newestTransactionEntriesForAccount
  :: Maybe Account
  -> [ActualTransactionEntry]
  -> [ActualTransactionEntry]
newestTransactionEntriesForAccount selectedAccount =
  reverse . transactionEntriesForAccount selectedAccount

-- | Failure to add a durable identity to one selected ordinary Actual fact.
--
-- Source coordinates are accepted only as parser-owned evidence from the same
-- admitted observation. They are never persisted as identity or relation data.
data ActualIdentityPromotionError
  = ActualIdentityPromotionTargetMissing
  | ActualIdentityPromotionTargetAmbiguous Int
  | ActualIdentityPromotionAlreadyIdentified ActualTransactionId
  | ActualIdentityPromotionIdAlreadyExists ActualTransactionId
  | ActualIdentityPromotionSourceCoordinateInvalid Int
  | ActualIdentityPromotionCandidateSyntaxError (NonEmpty.NonEmpty JournalError)
  | ActualIdentityPromotionCandidateAdmissionError (NonEmpty.NonEmpty ActualJournalError)
  | ActualIdentityPromotionCandidateMismatch
  deriving (Eq, Show)

-- | Pure candidate source for an optional identity promotion. Publishing remains
-- owned by the normal source-publication boundary.
data ActualIdentityPromotionPreview = ActualIdentityPromotionPreview
  { identityPromotionActualId                :: ActualTransactionId
  , identityPromotionCandidateCompleteSource :: Text
  } deriving (Eq, Show)

-- | Add explicit @event-id@ metadata to one selected identity-free Actual block
-- without changing its accounting Transaction.
--
-- The selected entry must come from the supplied admitted Actual observation.
-- Matching uses its retained parser-owned source evidence rather than date,
-- description, amount, Account shape, or Transaction equality. The candidate is
-- re-admitted against the same resolved Journal and rejected unless every
-- accounting Transaction remains unchanged and only the selected identity is
-- promoted.
prepareActualIdentityPromotion
  :: ActualJournal
  -> Text
  -> ActualTransactionEntry
  -> ActualTransactionId
  -> Either ActualIdentityPromotionError ActualIdentityPromotionPreview
prepareActualIdentityPromotion journal source selected requestedId = do
  targetIndex <- uniqueSelectedIndex
  case actualTransactionEntryIdentity selected of
    Just existingId -> Left (ActualIdentityPromotionAlreadyIdentified existingId)
    Nothing -> Right ()
  if requestedId `elem` existingIds
    then Left (ActualIdentityPromotionIdAlreadyExists requestedId)
    else Right ()
  candidateSource <- maybe
    (Left (ActualIdentityPromotionSourceCoordinateInvalid headerLine))
    Right
    (insertMetadataAfterLine
      headerLine
      ("  ; event-id: " <> actualTransactionIdText requestedId)
      source)
  document <- first ActualIdentityPromotionCandidateSyntaxError
    (parseJournalDocument candidateSource)
  candidate <- first ActualIdentityPromotionCandidateAdmissionError
    (admitActualJournalFromResolvedSources
      (actualJournalValue journal)
      (journalDocumentTransactionSources document))
  let originalEntries = actualJournalTransactionEntries journal
      candidateEntries = actualJournalTransactionEntries candidate
      originalTransactions = map actualTransactionEntryTransaction originalEntries
      candidateTransactions = map actualTransactionEntryTransaction candidateEntries
      originalIdentities = map actualTransactionEntryIdentity originalEntries
      candidateIdentities = map actualTransactionEntryIdentity candidateEntries
      expectedIdentities = replaceAt targetIndex (Just requestedId) originalIdentities
  if candidateTransactions /= originalTransactions
      || candidateIdentities /= expectedIdentities
    then Left ActualIdentityPromotionCandidateMismatch
    else Right ActualIdentityPromotionPreview
      { identityPromotionActualId = requestedId
      , identityPromotionCandidateCompleteSource = candidateSource
      }
  where
    entries = actualJournalTransactionEntries journal
    selectedSource = actualTransactionEntrySource selected
    selectedIdentity = actualTransactionEntryIdentity selected
    matches =
      [ index
      | (index, entry) <- zip [0..] entries
      , actualTransactionEntrySource entry == selectedSource
      , actualTransactionEntryIdentity entry == selectedIdentity
      ]
    uniqueSelectedIndex = case matches of
      [] -> Left ActualIdentityPromotionTargetMissing
      [index] -> Right index
      _ -> Left (ActualIdentityPromotionTargetAmbiguous (length matches))
    existingIds =
      map identifiedActualId (actualJournalIdentifiedTransactions journal)
    headerLine = journalTransactionSourceHeaderLine selectedSource

insertMetadataAfterLine :: Int -> Text -> Text -> Maybe Text
insertMetadataAfterLine lineNumber metadata source
  | lineNumber <= 0 = Nothing
  | otherwise =
      let sourceLines = T.splitOn "\n" source
          (before, after) = splitAt lineNumber sourceLines
      in if length before == lineNumber
          then Just (T.intercalate "\n" (before ++ metadata : after))
          else Nothing

replaceAt :: Int -> value -> [value] -> [value]
replaceAt index replacement values
  | index < 0 = values
  | otherwise = case splitAt index values of
      (before, _ : after) -> before ++ replacement : after
      _ -> values

transactionMatchesAccount :: Account -> Transaction -> Bool
transactionMatchesAccount selectedAccount =
  any
    ((== selectedAccount) . postingAccount)
    . NonEmpty.toList
    . transactionPostings
