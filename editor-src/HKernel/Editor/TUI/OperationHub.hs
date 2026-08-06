{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.OperationHub
  ( DailyOperation(..)
  , DisabledReason(..)
  , OperationAvailability(..)
  , OperationHubState(..)
  , OperationHubAction(..)
  , allDailyOperations
  , operationTitle
  , operationAvailability
  , initialOperationHubState
  , selectedOperation
  , transitionOperationHub
  , disabledReasonText
  ) where

import Data.Text (Text)

-- | Top-level operation vocabulary for daily h-kernel interactions.
data DailyOperation
  = OperationActualAdd
  | OperationActualMultiPosting
  | OperationActualReverse
  | OperationReports
  | OperationAccountDeclaration
  | OperationPlan
  | OperationBudgetMovement
  | OperationIssue
  deriving (Eq, Ord, Show, Bounded, Enum)

-- | Explicit reasons why an operation cannot be executed in the TUI yet.
data DisabledReason
  = OperationNotConnected
  | OperationAuthorityUnresolved
  | OperationAuthorityUnchanged
  deriving (Eq, Show)

-- | Availability state of a daily operation.
data OperationAvailability
  = OperationEnabled
  | OperationDisabled DisabledReason
  deriving (Eq, Show)

-- | Pure state of the top-level operation hub.
-- Retains only menu selection index, never private source or filesystem paths.
data OperationHubState = OperationHubState
  { hubSelectedIndex :: Int
  } deriving (Eq, Show)

data OperationHubAction
  = HubMoveUp
  | HubMoveDown
  | HubSelect
  deriving (Eq, Show)

-- | Deterministic menu order of all daily operations.
allDailyOperations :: [DailyOperation]
allDailyOperations = [minBound .. maxBound]

-- | Human-readable title of a daily operation.
operationTitle :: DailyOperation -> Text
operationTitle op = case op of
  OperationActualAdd          -> "Actual: Add Ordinary Transaction"
  OperationActualMultiPosting -> "Actual: Add Multi-posting Transaction"
  OperationActualReverse      -> "Actual: Reverse Transaction"
  OperationReports            -> "Reports: Read-only Surfaces"
  OperationAccountDeclaration -> "Account: Declare Account"
  OperationPlan               -> "Plan: Operations & Companion Sync"
  OperationBudgetMovement     -> "Budget: Add Movement"
  OperationIssue              -> "Issue: Operations"

-- | Availability classification for daily operations in this slice.
-- Only ordinary Actual add is enabled; all others are typed disabled states.
operationAvailability :: DailyOperation -> OperationAvailability
operationAvailability op = case op of
  OperationActualAdd          -> OperationEnabled
  OperationActualMultiPosting -> OperationDisabled OperationNotConnected
  OperationActualReverse      -> OperationDisabled OperationNotConnected
  OperationReports            -> OperationDisabled OperationNotConnected
  OperationAccountDeclaration -> OperationDisabled OperationNotConnected
  OperationPlan               -> OperationDisabled OperationAuthorityUnresolved
  OperationBudgetMovement     -> OperationDisabled OperationAuthorityUnchanged
  OperationIssue              -> OperationDisabled OperationAuthorityUnchanged

disabledReasonText :: DisabledReason -> Text
disabledReasonText reason = case reason of
  OperationNotConnected        -> "Not Connected"
  OperationAuthorityUnresolved -> "Writer Authority Unresolved"
  OperationAuthorityUnchanged  -> "Writer Authority Unchanged"

initialOperationHubState :: OperationHubState
initialOperationHubState = OperationHubState 0

selectedOperation :: OperationHubState -> DailyOperation
selectedOperation (OperationHubState idx) =
  let ops = allDailyOperations
      safeIdx = max 0 (min (length ops - 1) idx)
  in ops !! safeIdx

-- | Transition pure operation hub state upon user navigation action.
transitionOperationHub
  :: OperationHubAction
  -> OperationHubState
  -> OperationHubState
transitionOperationHub action state@(OperationHubState idx) = case action of
  HubMoveUp ->
    let newIdx = max 0 (idx - 1)
    in state { hubSelectedIndex = newIdx }
  HubMoveDown ->
    let maxIdx = length allDailyOperations - 1
        newIdx = min maxIdx (idx + 1)
    in state { hubSelectedIndex = newIdx }
  HubSelect -> state
