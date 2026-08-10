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
  , ActualMultiAddState(..)
  , initialActualMultiAddStateForDay
  , setActualMultiAddDate
  , setActualMultiDateText
  , setActualMultiDescription
  , selectActualMultiPosting
  , resizeActualMultiPostings
  , appendActualMultiPosting
  , removeSelectedActualMultiPosting
  , setSelectedActualMultiAccount
  , setSelectedActualMultiAccountText
  , setSelectedActualMultiAmount
  , selectedActualMultiPosting
  , multiAccountCandidates
  , filterMultiAccountCandidates
  ) where

import Data.List (findIndex)
import qualified Data.List.NonEmpty as NonEmpty
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

-- Multi-posting daily interaction

-- | General Actual row editor state. The selected index is zero-based and is
-- always clamped to an existing posting row. The operation owner still decides
-- whether these rows form a valid balanced transaction.
data ActualMultiAddState = ActualMultiAddState
  { actualMultiAddInput        :: ActualMultiAddInput
  , actualMultiSelectedPosting :: Int
  } deriving (Eq, Show)

initialActualMultiAddStateForDay :: Day -> ActualMultiAddState
initialActualMultiAddStateForDay day =
  ActualMultiAddState
    { actualMultiAddInput = ActualMultiAddInput
        { multiAddDateText = renderDay day
        , multiAddDescriptionText = ""
        , multiAddPostings =
            ActualPostingInput "" ""
              NonEmpty.:| [ActualPostingInput "" "", ActualPostingInput "" ""]
        }
    , actualMultiSelectedPosting = 0
    }

setActualMultiAddDate :: Day -> ActualMultiAddState -> ActualMultiAddState
setActualMultiAddDate day = setActualMultiDateText (renderDay day)

-- | Replace the raw date text without assigning date parsing to the delivery
-- toolkit. This keeps the multi-posting form usable with ordinary text entry
-- even when terminal-specific modified keys are unavailable.
setActualMultiDateText :: Text -> ActualMultiAddState -> ActualMultiAddState
setActualMultiDateText dateText state = state
  { actualMultiAddInput =
      (actualMultiAddInput state) { multiAddDateText = dateText }
  }

setActualMultiDescription :: Text -> ActualMultiAddState -> ActualMultiAddState
setActualMultiDescription description state = state
  { actualMultiAddInput =
      (actualMultiAddInput state) { multiAddDescriptionText = description }
  }

selectActualMultiPosting :: Int -> ActualMultiAddState -> ActualMultiAddState
selectActualMultiPosting requested state =
  state { actualMultiSelectedPosting = clampIndex requested rows }
  where
    rows = NonEmpty.toList (multiAddPostings (actualMultiAddInput state))

-- | Resize the editable posting table while preserving source order and the
-- contents of retained rows. Multi-posting entry always keeps at least three
-- rows because the ordinary two-posting case has its own shorter workflow.
-- A delivery can therefore expose posting count as an ordinary text field
-- instead of requiring function or modified keys for row insertion/removal.
resizeActualMultiPostings :: Int -> ActualMultiAddState -> ActualMultiAddState
resizeActualMultiPostings requested state = state
  { actualMultiAddInput = input { multiAddPostings = toNonEmpty resized }
  , actualMultiSelectedPosting = clampIndex selected resized
  }
  where
    input = actualMultiAddInput state
    rows = NonEmpty.toList (multiAddPostings input)
    selected = actualMultiSelectedPosting state
    desired = max 3 requested
    blanks = replicate (max 0 (desired - length rows)) (ActualPostingInput "" "")
    resized = take desired (rows <> blanks)

appendActualMultiPosting :: ActualMultiAddState -> ActualMultiAddState
appendActualMultiPosting state =
  let resized = resizeActualMultiPostings (length rows + 1) state
  in resized { actualMultiSelectedPosting = length rows }
  where
    rows = NonEmpty.toList (multiAddPostings (actualMultiAddInput state))

removeSelectedActualMultiPosting :: ActualMultiAddState -> ActualMultiAddState
removeSelectedActualMultiPosting state
  | length rows <= 3 = state
  | otherwise = state
      { actualMultiAddInput = input { multiAddPostings = toNonEmpty remaining }
      , actualMultiSelectedPosting = clampIndex selected remaining
      }
  where
    input = actualMultiAddInput state
    rows = NonEmpty.toList (multiAddPostings input)
    selected = actualMultiSelectedPosting state
    remaining = take selected rows <> drop (selected + 1) rows

setSelectedActualMultiAccount :: Account -> ActualMultiAddState -> ActualMultiAddState
setSelectedActualMultiAccount account =
  setSelectedActualMultiAccountText (accountName account)

-- | Set the selected row's Account text directly. Canonical Account admission
-- remains downstream in Actual candidate preparation; this function exists so
-- ordinary form editing does not depend on a terminal shortcut to open a picker.
setSelectedActualMultiAccountText :: Text -> ActualMultiAddState -> ActualMultiAddState
setSelectedActualMultiAccountText accountText =
  updateSelectedActualMultiPosting
    (\posting -> posting { multiPostingAccountText = accountText })

setSelectedActualMultiAmount :: Text -> ActualMultiAddState -> ActualMultiAddState
setSelectedActualMultiAmount amount =
  updateSelectedActualMultiPosting
    (\posting -> posting { multiPostingAmountText = amount })

selectedActualMultiPosting :: ActualMultiAddState -> ActualPostingInput
selectedActualMultiPosting state = rows !! selected
  where
    rows = NonEmpty.toList (multiAddPostings (actualMultiAddInput state))
    selected = clampIndex (actualMultiSelectedPosting state) rows

updateSelectedActualMultiPosting
  :: (ActualPostingInput -> ActualPostingInput)
  -> ActualMultiAddState
  -> ActualMultiAddState
updateSelectedActualMultiPosting update state = state
  { actualMultiAddInput = input { multiAddPostings = toNonEmpty updatedRows }
  }
  where
    input = actualMultiAddInput state
    rows = NonEmpty.toList (multiAddPostings input)
    selected = clampIndex (actualMultiSelectedPosting state) rows
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
