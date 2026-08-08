{-# LANGUAGE OverloadedStrings #-}

-- | UI-independent interaction state for Actual add workflows.
--
-- Brick, Haskeline, or another delivery adapter may map its own events and
-- widgets onto these states. Candidate preparation and write outcome meaning
-- remain owned by 'HKernel.Editor.ActualAppend'. This module owns no terminal
-- toolkit, cursor, widget, filesystem effect, or publication loop.
module HKernel.Editor.Interaction.ActualAdd
  ( AccountSelectionTarget(..)
  , ActualAddMode(..)
  , ActualAddState(..)
  , ActualAddAction(..)
  , initialActualAddState
  , initialActualAddStateForDay
  , setActualAddDate
  , dailyAccountCandidates
  , filterDailyAccountCandidates
  , enterActualAddPreview
  , transitionActualAdd
  , ActualMultiAddState(..)
  , initialActualMultiAddStateForDay
  , setActualMultiAddDate
  , setActualMultiDescription
  , selectActualMultiPosting
  , appendActualMultiPosting
  , removeSelectedActualMultiPosting
  , setSelectedActualMultiAccount
  , setSelectedActualMultiAmount
  , selectedActualMultiPosting
  , multiAccountCandidates
  , filterMultiAccountCandidates
  ) where

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
  , ActualAddPreview(..)
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

data ActualAddMode
  = EditingActualAdd
  | SelectingActualAccount AccountSelectionTarget
  | ShowingActualAddPreview ActualAddPreview
  deriving (Eq, Show)

data ActualAddState = ActualAddState
  { actualAddInput :: ActualAddInput
  , actualAddMode  :: ActualAddMode
  } deriving (Eq, Show)

data ActualAddAction
  = BeginAccountSelection AccountSelectionTarget
  | ChooseAccount Account
  | CancelAccountSelection
  | ReturnToActualAddInput
  deriving (Eq, Show)

initialActualAddState :: ActualAddState
initialActualAddState = ActualAddState emptyActualAddInput EditingActualAdd

-- | Start a daily entry with its ordinary day already chosen. Delivery adapters
-- can use today's local Day without turning "today" into persisted metadata.
initialActualAddStateForDay :: Day -> ActualAddState
initialActualAddStateForDay day =
  ActualAddState
    (emptyActualAddInput { addDateText = renderDay day })
    EditingActualAdd

-- | Replace only the chosen accounting day. Today/yesterday shortcuts remain
-- a delivery concern; this function keeps the resulting input transformation
-- toolkit-independent.
setActualAddDate :: Day -> ActualAddState -> ActualAddState
setActualAddDate day state =
  state
    { actualAddInput =
        (actualAddInput state) { addDateText = renderDay day }
    }

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

-- | Case-insensitive substring search over Account names. Empty search preserves
-- the recent-first order from 'dailyAccountCandidates'.
filterDailyAccountCandidates :: Text -> [Account] -> [Account]
filterDailyAccountCandidates = filterAccountCandidates

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

-- | Enter preview mode with a preview prepared by the Actual operation owner.
-- Interaction does not need the complete source that produced this value.
-- A ready preview is already the single human confirmation surface; delivery
-- adapters may explicitly publish its candidate block without introducing a
-- second interaction state containing the same information.
enterActualAddPreview :: ActualAddPreview -> ActualAddState -> ActualAddState
enterActualAddPreview preview state =
  state { actualAddMode = ShowingActualAddPreview preview }

-- | Apply one source-independent interaction action to the ordinary Actual add
-- workflow. Candidate preparation remains owned by 'HKernel.Editor.ActualAppend';
-- publication is an explicit delivery effect from a ready preview, not another
-- duplicated state transition.
transitionActualAdd
  :: ActualAddAction
  -> ActualAddState
  -> ActualAddState
transitionActualAdd action state = case action of
  BeginAccountSelection target ->
    state { actualAddMode = SelectingActualAccount target }
  ChooseAccount account -> case actualAddMode state of
    SelectingActualAccount SelectFromAccount ->
      state
        { actualAddInput =
            (actualAddInput state) { addFromAccountText = accountName account }
        , actualAddMode = EditingActualAdd
        }
    SelectingActualAccount SelectToAccount ->
      state
        { actualAddInput =
            (actualAddInput state) { addToAccountText = accountName account }
        , actualAddMode = EditingActualAdd
        }
    _ -> state
  CancelAccountSelection -> case actualAddMode state of
    SelectingActualAccount _ -> state { actualAddMode = EditingActualAdd }
    _ -> state
  ReturnToActualAddInput -> state { actualAddMode = EditingActualAdd }

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
setActualMultiAddDate day state = state
  { actualMultiAddInput =
      (actualMultiAddInput state) { multiAddDateText = renderDay day }
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

appendActualMultiPosting :: ActualMultiAddState -> ActualMultiAddState
appendActualMultiPosting state = state
  { actualMultiAddInput = input
      { multiAddPostings = toNonEmpty (rows <> [ActualPostingInput "" ""])
      }
  , actualMultiSelectedPosting = length rows
  }
  where
    input = actualMultiAddInput state
    rows = NonEmpty.toList (multiAddPostings input)

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
  updateSelectedActualMultiPosting
    (\posting -> posting { multiPostingAccountText = accountName account })

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
