{-# LANGUAGE OverloadedStrings #-}

-- | UI-independent interaction helpers for Actual add workflows.
--
-- Delivery adapters own their workflow state and map their own events and
-- widgets onto these pure input/candidate transformations. Candidate
-- preparation and write outcome meaning remain owned by
-- 'HKernel.Editor.ActualAppend'. This module owns no terminal toolkit, cursor,
-- widget, filesystem effect, publication loop, or duplicate single-entry state
-- machine.
module HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , initialActualAddInputForDay
  , selectActualAddAccount
  , dailyAccountCandidates
  , incomeAccountCandidates
  , filterDailyAccountCandidates
  , groupAccountCandidates
  , stepAccountCandidate
  , initialActualMultiAddInputForDay
  , initialActualMultiAddInputForDescription
  , resizeActualMultiPostings
  , actualMultiPostingAt
  , setActualMultiPostingAccountText
  , setActualMultiPostingAmount
  , multiAccountCandidates
  , filterMultiAccountCandidates
  , moveMultiAccountCandidateCursor
  , resetMultiAccountCandidateCursor
  , resolveMultiAccountCandidate
  , commitMultiAccountCandidate
  , accountCandidateAt
  ) where

import Data.List (findIndex)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)

import HKernel.Account
  ( Account
  , AccountRegistry
  , AccountType(..)
  , accountDeclarations
  , accountName
  , accountTypeFor
  , declaredAccount
  )
import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualMultiAddInput(..)
  , ActualPostingInput(..)
  , emptyActualAddInput
  )
import HKernel.Ledger
  ( Transaction
  , postingAccount
  , transactionPostings
  )

data AccountSelectionTarget
  = SelectFromAccount
  | SelectToAccount
  deriving (Eq, Show)

-- | Start one ordinary Actual input with its accounting day already chosen.
-- Delivery adapters can use today's local Day without turning "today" into
-- persisted metadata or mirroring their own workflow state here.
initialActualAddInputForDay :: Day -> ActualAddInput
initialActualAddInputForDay day =
  emptyActualAddInput { addDateText = renderDay day }

-- | Replace only the selected Account field in one ordinary Actual input.
-- Delivery focus/cursor state remains outside this module.
selectActualAddAccount
  :: AccountSelectionTarget
  -> Account
  -> ActualAddInput
  -> ActualAddInput
selectActualAddAccount target account input = case target of
  SelectFromAccount -> input { addFromAccountText = accountName account }
  SelectToAccount -> input { addToAccountText = accountName account }

renderDay :: Day -> Text
renderDay = T.pack . show

-- | Daily expense entry exposes only meaningful roles and orders them by recent
-- Actual use. Expense destinations are categories; payment sources are Asset or
-- Liability Accounts. Remaining matching Accounts retain canonical registry
-- order after the recent prefix.
dailyAccountCandidates
  :: AccountRegistry
  -> [Transaction]
  -> AccountSelectionTarget
  -> [Account]
dailyAccountCandidates registry transactions target =
  recentFirstCandidates transactions allMatching
  where
    allMatching =
      filter (matchesDailyRole registry target)
        (map declaredAccount (accountDeclarations registry))

-- | Daily income entry exposes Income sources and Asset destinations while
-- reusing the same ordinary two-posting Actual input. Account-role meaning
-- stays here rather than in the Brick delivery adapter.
incomeAccountCandidates
  :: AccountRegistry
  -> [Transaction]
  -> AccountSelectionTarget
  -> [Account]
incomeAccountCandidates registry transactions target =
  recentFirstCandidates transactions allMatching
  where
    allMatching =
      filter (matchesIncomeRole registry target)
        (map declaredAccount (accountDeclarations registry))

-- | Case-insensitive substring search over Account names. Empty search preserves
-- the recent-first order from 'dailyAccountCandidates'.
filterDailyAccountCandidates :: Text -> [Account] -> [Account]
filterDailyAccountCandidates = filterAccountCandidates

-- | Partition an already-admitted candidate set by typed accounting meaning.
-- Group order is stable and explicit; Account order inside each group preserves
-- the caller's order, including any recent-first ranking already applied.
groupAccountCandidates
  :: AccountRegistry
  -> [Account]
  -> [(AccountType, [Account])]
groupAccountCandidates registry candidates =
  [ (accountType, matching)
  | accountType <- [Asset, Liability, Equity, Income, Expense, Budget]
  , let matching = filter ((== Just accountType) . (`accountTypeFor` registry)) candidates
  , not (null matching)
  ]

-- | Move through an exact candidate list without creating separate selector
-- state. A delivery may use the Account field's current text as the current
-- selection. Unknown or blank text enters at the nearest end in the requested
-- direction, while known selections wrap around.
stepAccountCandidate :: Int -> Text -> [Account] -> Maybe Account
stepAccountCandidate _ _ [] = Nothing
stepAccountCandidate offset currentText candidates =
  Just (candidates !! nextIndex)
  where
    currentIndex = findIndex ((== T.strip currentText) . accountName) candidates
    count = length candidates
    nextIndex = case currentIndex of
      Just index -> (index + offset) `mod` count
      Nothing
        | offset < 0 -> count - 1
        | otherwise -> 0

matchesDailyRole
  :: AccountRegistry
  -> AccountSelectionTarget
  -> Account
  -> Bool
matchesDailyRole registry target account =
  case (target, accountTypeFor account registry) of
    (SelectToAccount, Just Expense) -> True
    (SelectFromAccount, Just Asset) -> True
    (SelectFromAccount, Just Liability) -> True
    _ -> False

matchesIncomeRole
  :: AccountRegistry
  -> AccountSelectionTarget
  -> Account
  -> Bool
matchesIncomeRole registry target account =
  case (target, accountTypeFor account registry) of
    (SelectToAccount, Just Asset) -> True
    (SelectFromAccount, Just Income) -> True
    _ -> False

-- General Record interaction

-- | Start one delivery-neutral general Record draft. Selection and other widget
-- state belong to the delivery adapter rather than to the Actual input.
initialActualMultiAddInputForDay :: Day -> ActualMultiAddInput
initialActualMultiAddInputForDay day = ActualMultiAddInput
  { multiAddDateText = renderDay day
  , multiAddDescriptionText = ""
  , multiAddPostings =
      ActualPostingInput "" "" NonEmpty.:| [ActualPostingInput "" ""]
  }

-- | Start the same general Record draft with an optional initial description.
-- Issue realization uses this only to seed the shared description field; all
-- posting rows and their editing semantics remain ordinary Record state.
initialActualMultiAddInputForDescription :: Day -> Text -> ActualMultiAddInput
initialActualMultiAddInputForDescription day description =
  (initialActualMultiAddInputForDay day)
    { multiAddDescriptionText = description }

-- | Resize the editable posting table while preserving source order and the
-- contents of retained rows. General Record entry always keeps the Transaction
-- domain minimum of two rows. A delivery can therefore expose posting count as
-- an ordinary text field instead of requiring function or modified keys for
-- row insertion/removal.
resizeActualMultiPostings :: Int -> ActualMultiAddInput -> ActualMultiAddInput
resizeActualMultiPostings requested input =
  input { multiAddPostings = toNonEmpty resized }
  where
    rows = NonEmpty.toList (multiAddPostings input)
    desired = max 2 requested
    blanks = replicate (max 0 (desired - length rows)) (ActualPostingInput "" "")
    resized = take desired (rows <> blanks)

actualMultiPostingAt :: Int -> ActualMultiAddInput -> ActualPostingInput
actualMultiPostingAt requested input = rows !! clampIndex requested rows
  where
    rows = NonEmpty.toList (multiAddPostings input)

-- | Set one row's raw Account text. Canonical Account admission remains
-- downstream in Actual candidate preparation.
setActualMultiPostingAccountText
  :: Int
  -> Text
  -> ActualMultiAddInput
  -> ActualMultiAddInput
setActualMultiPostingAccountText selected accountText =
  updateActualMultiPosting selected
    (\posting -> posting { multiPostingAccountText = accountText })

setActualMultiPostingAmount
  :: Int
  -> Text
  -> ActualMultiAddInput
  -> ActualMultiAddInput
setActualMultiPostingAmount selected amount =
  updateActualMultiPosting selected
    (\posting -> posting { multiPostingAmountText = amount })

updateActualMultiPosting
  :: Int
  -> (ActualPostingInput -> ActualPostingInput)
  -> ActualMultiAddInput
  -> ActualMultiAddInput
updateActualMultiPosting requested update input =
  input { multiAddPostings = toNonEmpty updatedRows }
  where
    rows = NonEmpty.toList (multiAddPostings input)
    selected = clampIndex requested rows
    updatedRows =
      [ if index == selected then update posting else posting
      | (index, posting) <- zip [0 ..] rows
      ]

-- | Multi entry may use any canonical Account. Recently used Accounts come
-- first, then unused declarations retain registry order. This is intentionally
-- broader than ordinary expense entry because split transactions can represent
-- transfers, income, liabilities, equity, or mixed accounting coordinates.
multiAccountCandidates :: AccountRegistry -> [Transaction] -> [Account]
multiAccountCandidates registry transactions =
  recentFirstCandidates transactions
    (map declaredAccount (accountDeclarations registry))

filterMultiAccountCandidates :: Text -> [Account] -> [Account]
filterMultiAccountCandidates = filterAccountCandidates

-- | Move a delivery-local cursor over exactly the currently filtered Account
-- candidates. The raw Account field remains the query and is never changed by
-- cursor movement. Unknown cursors enter at the requested end; known cursors
-- wrap within the filtered set.
moveMultiAccountCandidateCursor
  :: Int
  -> Text
  -> Maybe Int
  -> [Account]
  -> Maybe Int
moveMultiAccountCandidateCursor offset query current candidates
  | null filtered = Nothing
  | otherwise = Just next
  where
    filtered = filterMultiAccountCandidates query candidates
    count = length filtered
    next = case current of
      Just index | index >= 0 && index < count -> (index + offset) `mod` count
      _ | offset < 0 -> count - 1
        | otherwise -> 0

-- | Keep the delivery-local cursor only while the raw query is unchanged.
-- Typing, deletion, or a posting-row change starts navigation safely from an
-- unselected candidate set.
resetMultiAccountCandidateCursor :: Text -> Text -> Maybe Int -> Maybe Int
resetMultiAccountCandidateCursor previousQuery nextQuery cursor
  | previousQuery == nextQuery = cursor
  | otherwise = Nothing

-- | Resolve a transient cursor or mouse coordinate against the same current
-- filtered set. A stale or out-of-range coordinate is a safe no-op.
resolveMultiAccountCandidate :: Text -> Int -> [Account] -> Maybe Account
resolveMultiAccountCandidate query index =
  accountCandidateAt index . filterMultiAccountCandidates query

-- | Commit one keyboard or mouse candidate coordinate to the addressed posting.
-- Both delivery paths use this operation after resolving the same filtered set.
commitMultiAccountCandidate
  :: Int
  -> Text
  -> Int
  -> [Account]
  -> ActualMultiAddInput
  -> Maybe ActualMultiAddInput
commitMultiAccountCandidate postingIndex query candidateIndex candidates input = do
  account <- resolveMultiAccountCandidate query candidateIndex candidates
  pure (setActualMultiPostingAccountText postingIndex (accountName account) input)

accountCandidateAt :: Int -> [Account] -> Maybe Account
accountCandidateAt index candidates
  | index < 0 = Nothing
  | otherwise = listToMaybe (drop index candidates)

recentFirstCandidates :: [Transaction] -> [Account] -> [Account]
recentFirstCandidates transactions candidates =
  recentMatching <> remaining
  where
    candidateSet = Set.fromList candidates
    recentMatching =
      uniqueAccounts
        [ account
        | transaction <- reverse transactions
        , posting <- NonEmpty.toList (transactionPostings transaction)
        , let account = postingAccount posting
        , Set.member account candidateSet
        ]
    recentSet = Set.fromList recentMatching
    remaining = filter (`Set.notMember` recentSet) candidates

filterAccountCandidates :: Text -> [Account] -> [Account]
filterAccountCandidates query
  | T.null normalizedQuery = id
  | otherwise = filter (T.isInfixOf normalizedQuery . T.toCaseFold . accountName)
  where
    normalizedQuery = T.toCaseFold (T.strip query)

uniqueAccounts :: [Account] -> [Account]
uniqueAccounts = go Set.empty
  where
    go _ [] = []
    go seen (account : rest)
      | Set.member account seen = go seen rest
      | otherwise = account : go (Set.insert account seen) rest

clampIndex :: Int -> [a] -> Int
clampIndex _ [] = 0
clampIndex requested values = max 0 (min requested (length values - 1))

toNonEmpty :: [a] -> NonEmpty.NonEmpty a
toNonEmpty values = case NonEmpty.nonEmpty values of
  Just nonEmpty -> nonEmpty
  Nothing -> error "Actual multi-posting interaction invariant: rows are non-empty"
