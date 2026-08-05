{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.TUI.ActualAdd
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

import Data.Bifunctor (first)
import Data.List.NonEmpty (NonEmpty(..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)

import HKernel.Account (mkAccount)
import HKernel.Editor.ActualAppend
  ( ActualAppendPreview(..)
  , ActualEditError
  , ActualEditIntent(..)
  , prepareActualAppend
  )
import HKernel.Editor.ActualWriter (WriteError(..))
import HKernel.Editor.TransactionBlock (IntentPosting(..))
import HKernel.Money
  ( mkCommodity
  , negateQuantity
  , parseQuantity
  , quantityToRational
  )

-- | Text entered by the Actual-add TUI before domain admission.
data ActualAddInput = ActualAddInput
  { addDateText        :: Text
  , addDescriptionText :: Text
  , addFromAccountText :: Text
  , addToAccountText   :: Text
  , addAmountText      :: Text
  } deriving (Eq, Show)

data ActualAddInputError
  = ActualAddInvalidDate
  | ActualAddInvalidFromAccount
  | ActualAddInvalidToAccount
  | ActualAddInvalidAmountShape
  | ActualAddInvalidQuantity
  | ActualAddAmountMustBePositive
  | ActualAddInvalidCommodity
  deriving (Eq, Show)

-- | Preview state retains only the candidate block, never the complete private
-- source supplied to validation.
data ActualAddPreview
  = ActualAddInputRejected ActualAddInputError
  | ActualAddCandidateRejected (NonEmpty ActualEditError)
  | ActualAddCandidateReady Text
  deriving (Eq, Show)

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

-- | Delivery-level failure kind presented by the Actual-add TUI.
--
-- This keeps filesystem and admission details out of the Brick event loop
-- while preserving whether automatic restoration completed.
data ActualAddWriteFailure
  = ActualAddPostAdmissionFailure
  | ActualAddPostPublishReadFailure
  | ActualAddFileIOFailure String
  deriving (Eq, Show)

data ActualAddWriteOutcome
  = ActualAddWriteSucceeded
  | ActualAddWriteStale
  | ActualAddWriteRecovered ActualAddWriteFailure
  | ActualAddWriteFailed ActualAddWriteFailure
  deriving (Eq, Show)

emptyActualAddInput :: ActualAddInput
emptyActualAddInput = ActualAddInput "" "" "" "" ""

initialActualAddState :: ActualAddState
initialActualAddState = ActualAddState emptyActualAddInput EditingActualAdd

-- | Admit a positive magnitude and derive the balancing source posting by
-- negating the parsed Quantity value, never by manipulating its input text.
buildActualAddIntent
  :: ActualAddInput
  -> Either ActualAddInputError ActualEditIntent
buildActualAddIntent input = do
  date <- maybe (Left ActualAddInvalidDate) Right
    (parseTimeM
      True
      defaultTimeLocale
      "%Y-%m-%d"
      (T.unpack (addDateText input)) :: Maybe Day)
  fromAccount <- first (const ActualAddInvalidFromAccount)
    (mkAccount (addFromAccountText input))
  toAccount <- first (const ActualAddInvalidToAccount)
    (mkAccount (addToAccountText input))
  (quantityText, commodityText) <- case T.words (addAmountText input) of
    [quantityValue, commodityValue] -> Right (quantityValue, commodityValue)
    _ -> Left ActualAddInvalidAmountShape
  quantity <- first (const ActualAddInvalidQuantity)
    (parseQuantity quantityText)
  if quantityToRational quantity <= 0
    then Left ActualAddAmountMustBePositive
    else pure ()
  commodity <- first (const ActualAddInvalidCommodity)
    (mkCommodity commodityText)
  pure
    (ActualEditIntent
      date
      (addDescriptionText input)
      ( IntentPosting toAccount quantity (Just commodity)
        :| [IntentPosting fromAccount (negateQuantity quantity) (Just commodity)]
      )
      [])

prepareActualAddPreview :: Text -> ActualAddInput -> ActualAddPreview
prepareActualAddPreview source input =
  case buildActualAddIntent input of
    Left inputError -> ActualAddInputRejected inputError
    Right intent -> case prepareActualAppend source intent of
      Left sourceErrors -> ActualAddCandidateRejected sourceErrors
      Right preview -> ActualAddCandidateReady (candidateBlock preview)

-- | Pure interaction contract used by the Brick adapter and focused tests.
-- The admitted source is supplied to the transition and is not retained in UI
-- state or diagnostics. Confirmation records only the user's decision; source
-- writing remains a separate effect owned by the delivery adapter and writer.
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

-- | Collapse the safe writer result into the finite outcomes the interaction
-- layer can present. The complete source and source-local admission errors are
-- never retained in UI state.
classifyActualAddWriteResult
  :: Either (WriteError sourceError) ()
  -> ActualAddWriteOutcome
classifyActualAddWriteResult result = case result of
  Right () -> ActualAddWriteSucceeded
  Left StaleFile -> ActualAddWriteStale
  Left (PostAdmissionFailed { restoredFromBackup = True }) ->
    ActualAddWriteRecovered ActualAddPostAdmissionFailure
  Left (PostAdmissionFailed { restoredFromBackup = False }) ->
    ActualAddWriteFailed ActualAddPostAdmissionFailure
  Left (PostPublishReadFailed { restoredFromBackup = True }) ->
    ActualAddWriteRecovered ActualAddPostPublishReadFailure
  Left (PostPublishReadFailed { restoredFromBackup = False }) ->
    ActualAddWriteFailed ActualAddPostPublishReadFailure
  Left (FileIOError message) ->
    ActualAddWriteFailed (ActualAddFileIOFailure message)
