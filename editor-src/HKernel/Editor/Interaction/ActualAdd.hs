{-# LANGUAGE OverloadedStrings #-}

-- | UI-independent interaction state for the ordinary Actual add workflow.
--
-- Brick, Haskeline, or another delivery adapter may map its own events and
-- widgets onto these actions and states. This module owns no terminal toolkit,
-- cursor, widget, filesystem effect, or publication loop.
module HKernel.Editor.Interaction.ActualAdd
  ( ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddPreview(..)
  , AccountSelectionTarget(..)
  , ActualAddMode(..)
  , ActualAddState(..)
  , ActualAddAction(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , emptyActualAddInput
  , initialActualAddState
  , buildActualAddIntent
  , prepareActualAddPreview
  , transitionActualAdd
  , classifyActualAddWriteResult
  ) where

import Data.Text (Text)

import HKernel.Editor.ActualAppend
  ( ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , buildActualAddIntent
  , classifyActualAddWriteResult
  , emptyActualAddInput
  , prepareActualAddPreview
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
  | ChooseAccount Text
  | CancelAccountSelection
  | RequestActualAddPreview
  | RequestActualAddConfirmation
  | CancelActualAddConfirmation
  | ConfirmActualAdd
  | ReturnToActualAddInput
  deriving (Eq, Show)

initialActualAddState :: ActualAddState
initialActualAddState = ActualAddState emptyActualAddInput EditingActualAdd

-- | Apply one UI-independent interaction action to the ordinary Actual add
-- workflow. Source admission and candidate preparation remain owned by
-- 'HKernel.Editor.ActualAppend'; delivery adapters only choose when to issue
-- these actions and how to present the resulting state.
transitionActualAdd
  :: Text
  -> ActualAddAction
  -> ActualAddState
  -> ActualAddState
transitionActualAdd source action state = case action of
  BeginAccountSelection target ->
    state { actualAddMode = SelectingActualAccount target }
  ChooseAccount accountText -> case actualAddMode state of
    SelectingActualAccount SelectFromAccount ->
      state
        { actualAddInput =
            (actualAddInput state) { addFromAccountText = accountText }
        , actualAddMode = EditingActualAdd
        }
    SelectingActualAccount SelectToAccount ->
      state
        { actualAddInput =
            (actualAddInput state) { addToAccountText = accountText }
        , actualAddMode = EditingActualAdd
        }
    _ -> state
  CancelAccountSelection -> case actualAddMode state of
    SelectingActualAccount _ -> state { actualAddMode = EditingActualAdd }
    _ -> state
  RequestActualAddPreview ->
    state
      { actualAddMode =
          ShowingActualAddPreview
            (prepareActualAddPreview source (actualAddInput state))
      }
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
