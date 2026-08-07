{-# LANGUAGE OverloadedStrings #-}

-- | UI-independent interaction state for the ordinary Actual add workflow.
--
-- Brick, Haskeline, or another delivery adapter may map its own events and
-- widgets onto these actions and states. Candidate preparation and write
-- outcome meaning remain owned by 'HKernel.Editor.ActualAppend'. This module
-- owns no terminal toolkit, cursor, widget, filesystem effect, or publication
-- loop.
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
  | ConfirmingActualAdd Text
  | ActualAddConfirmed Text
  deriving (Eq, Show)

data ActualAddState = ActualAddState
  { actualAddInput :: ActualAddInput
  , actualAddMode  :: ActualAddMode
  } deriving (Eq, Show)

data ActualAddAction
  = BeginAccountSelection AccountSelectionTarget
  | ChooseAccount Account
  | CancelAccountSelection
  | RequestActualAddConfirmation
  | CancelActualAddConfirmation
  | ConfirmActualAdd
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
  recentMatching <> remaining
  where
    allMatching =
      filter (matchesDailyRole registry target)
        (map declaredAccount (accountDeclarations registry))
    matchingSet = Set.fromList allMatching
    recentMatching =
      uniqueAccounts
        [ account
        | transaction <- reverse transactions
        , posting <- NonEmpty.toList (transactionPostings transaction)
        , let account = postingAccount posting
        , Set.member account matchingSet
        ]
    recentSet = Set.fromList recentMatching
    remaining = filter (`Set.notMember` recentSet) allMatching

-- | Case-insensitive substring search over Account names. Empty search preserves
-- the recent-first order from 'dailyAccountCandidates'.
filterDailyAccountCandidates :: Text -> [Account] -> [Account]
filterDailyAccountCandidates query
  | T.null normalizedQuery = id
  | otherwise = filter (T.isInfixOf normalizedQuery . T.toCaseFold . accountName)
  where
    normalizedQuery = T.toCaseFold (T.strip query)

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

uniqueAccounts :: [Account] -> [Account]
uniqueAccounts = go Set.empty
  where
    go _ [] = []
    go seen (account : rest)
      | Set.member account seen = go seen rest
      | otherwise = account : go (Set.insert account seen) rest

-- | Enter preview mode with a preview prepared by the Actual operation owner.
-- Interaction does not need the complete source that produced this value.
enterActualAddPreview :: ActualAddPreview -> ActualAddState -> ActualAddState
enterActualAddPreview preview state =
  state { actualAddMode = ShowingActualAddPreview preview }

-- | Apply one source-independent interaction action to the ordinary Actual add
-- workflow. Candidate preparation remains owned by 'HKernel.Editor.ActualAppend';
-- delivery adapters supply the resulting preview through 'enterActualAddPreview'.
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
  RequestActualAddConfirmation -> case actualAddMode state of
    ShowingActualAddPreview (ActualAddCandidateReady block) ->
      state { actualAddMode = ConfirmingActualAdd block }
    _ -> state
  CancelActualAddConfirmation -> case actualAddMode state of
    ConfirmingActualAdd block ->
      state
        { actualAddMode =
            ShowingActualAddPreview (ActualAddCandidateReady block)
        }
    _ -> state
  ConfirmActualAdd -> case actualAddMode state of
    ConfirmingActualAdd block ->
      state { actualAddMode = ActualAddConfirmed block }
    _ -> state
  ReturnToActualAddInput -> state { actualAddMode = EditingActualAdd }