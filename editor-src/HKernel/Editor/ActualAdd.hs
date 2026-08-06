{-# LANGUAGE OverloadedStrings #-}

module HKernel.Editor.ActualAdd
  ( ActualAddInput(..)
  , ActualAddInputError(..)
  , ActualAddPreview(..)
  , ActualAddWriteFailure(..)
  , ActualAddWriteOutcome(..)
  , emptyActualAddInput
  , buildActualAddIntent
  , prepareActualAddPreview
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

-- | Delivery-neutral text input for the ordinary two-posting Actual add
-- operation. Brick, Haskeline, HTTP, or another adapter may construct the same
-- value before handing it to the shared application boundary.
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

-- | Preview retains only the candidate transaction block, never the complete
-- private source used for validation.
data ActualAddPreview
  = ActualAddInputRejected ActualAddInputError
  | ActualAddCandidateRejected (NonEmpty ActualEditError)
  | ActualAddCandidateReady Text
  deriving (Eq, Show)

-- | Delivery-neutral publication failure classes for ordinary Actual add.
data ActualAddWriteFailure
  = ActualAddPostAdmissionFailure
  | ActualAddPostPublishReadFailure
  deriving (Eq, Show)

data ActualAddWriteOutcome
  = ActualAddWriteSucceeded
  | ActualAddWriteStale
  | ActualAddWriteRecovered ActualAddWriteFailure
  | ActualAddWriteFailed ActualAddWriteFailure
  | ActualAddWriteFileIOFailed
  deriving (Eq, Show)

emptyActualAddInput :: ActualAddInput
emptyActualAddInput = ActualAddInput "" "" "" "" ""

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

-- | Collapse the safe writer result into a finite delivery-neutral outcome.
-- Complete source text and source-local admission errors never enter the result.
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
  Left (FileIOError _) ->
    ActualAddWriteFileIOFailed
