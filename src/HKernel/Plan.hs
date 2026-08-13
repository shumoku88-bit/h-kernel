{-# LANGUAGE OverloadedStrings #-}

-- | Admitted future outgoing commitments with durable identity.
--
-- A committed Plan is not a Journal transaction and does not change account
-- balances by itself. It preserves exact payment evidence that a later
-- Plan-to-Actual relation can use without guessing from date, memo, or amount.
module HKernel.Plan
  ( PlanId
  , PlanIdError(..)
  , mkPlanId
  , planIdText
  , PlanRetirement
  , PlanRetirementError(..)
  , declarePlanCancellation
  , declarePlanSupersession
  , retiredPlanId
  , planRetiredOn
  , planRetirementSuccessor
  , PositiveAmount
  , PositiveAmountError(..)
  , mkPositiveAmount
  , positiveAmountValue
  , PaymentDirection
  , PaymentDirectionError(..)
  , mkPaymentDirection
  , paymentDirectionFrom
  , paymentDirectionTo
  , DeclaredPaymentDirection
  , PaymentDirectionAdmissionError(..)
  , admitPaymentDirection
  , declaredPaymentSource
  , declaredPaymentDestination
  , DeclaredOutgoingPaymentDirection
  , OutgoingPaymentDirectionAdmissionError(..)
  , admitOutgoingPaymentDirection
  , declaredOutgoingPaymentDirection
  , CommittedOutgoingPlan
  , CommittedOutgoingPlanError(..)
  , mkCommittedOutgoingPlan
  , committedPlanId
  , committedPlanDate
  , committedPlanMemo
  , committedPlanAmount
  , committedPlanDirection
  ) where

import Data.Char (isControl, isSpace)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import HKernel.Account
  ( Account
  , AccountDeclaration
  , AccountRegistry
  , AccountType(..)
  , declaredAccountType
  , lookupAccountDeclaration
  )
import HKernel.Money
  ( Amount
  , amountQuantity
  , zeroQuantity
  )

-- | Stable identity used to connect one Plan to later Actual evidence.
newtype PlanId = PlanId { planIdText :: Text }
  deriving (Eq, Ord, Show)

data PlanIdError
  = EmptyPlanId
  | PlanIdHasSurroundingWhitespace Text
  | PlanIdContainsControlCharacter Text
  | PlanIdContainsWhitespace Text
  deriving (Eq, Show)

mkPlanId :: Text -> Either PlanIdError PlanId
mkPlanId value
  | T.null value = Left EmptyPlanId
  | T.strip value /= value = Left (PlanIdHasSurroundingWhitespace value)
  | T.any isControl value = Left (PlanIdContainsControlCharacter value)
  | T.any isSpace value = Left (PlanIdContainsWhitespace value)
  | otherwise = Right (PlanId value)

-- | Historical evidence that one Plan stopped being an active commitment.
--
-- Cancellation has no successor. Supersession names the fresh Plan identity
-- that replaced the old commitment. The old Plan transaction itself remains a
-- separate historical fact; retirement never rewrites its amount, date, memo,
-- or postings.
data PlanRetirement
  = PlanCancellation PlanId Day
  | PlanSupersession PlanId Day PlanId
  deriving (Eq, Show)

data PlanRetirementError
  = PlanCannotSupersedeItself PlanId
  deriving (Eq, Show)

-- | Declare that a Plan stopped being pursued without a replacement Plan.
declarePlanCancellation :: PlanId -> Day -> PlanRetirement
declarePlanCancellation = PlanCancellation

-- | Declare that a changed household commitment replaced one Plan with another
-- durable Plan identity.
--
-- Cross-Plan existence and supersession-cycle checks require a collection of
-- admitted Plans and therefore belong to the later journal admission boundary.
declarePlanSupersession
  :: PlanId
  -> Day
  -> PlanId
  -> Either PlanRetirementError PlanRetirement
declarePlanSupersession oldPlan retiredOn successor
  | oldPlan == successor = Left (PlanCannotSupersedeItself oldPlan)
  | otherwise = Right (PlanSupersession oldPlan retiredOn successor)

retiredPlanId :: PlanRetirement -> PlanId
retiredPlanId retirement = case retirement of
  PlanCancellation planId _ -> planId
  PlanSupersession planId _ _ -> planId

planRetiredOn :: PlanRetirement -> Day
planRetiredOn retirement = case retirement of
  PlanCancellation _ day -> day
  PlanSupersession _ day _ -> day

planRetirementSuccessor :: PlanRetirement -> Maybe PlanId
planRetirementSuccessor retirement = case retirement of
  PlanCancellation _ _ -> Nothing
  PlanSupersession _ _ successor -> Just successor

-- | Exact single-commodity amount proven to be strictly positive.
--
-- The constructor is hidden so a committed outgoing payment cannot carry zero
-- or negative quantity after this boundary has admitted it.
newtype PositiveAmount = PositiveAmount
  { positiveAmountValue :: Amount
  } deriving (Eq, Show)

data PositiveAmountError
  = NonPositiveAmount Amount
  deriving (Eq, Show)

mkPositiveAmount :: Amount -> Either PositiveAmountError PositiveAmount
mkPositiveAmount amount
  | amountQuantity amount <= zeroQuantity = Left (NonPositiveAmount amount)
  | otherwise = Right (PositiveAmount amount)

-- | Explicit direction of one payment between two distinct ledger accounts.
--
-- This local value does not yet prove that either account has been declared.
-- Registry admission is a separate step so local shape and repository evidence
-- remain visible as different meanings.
data PaymentDirection = PaymentDirection
  { paymentDirectionFrom :: Account
  , paymentDirectionTo   :: Account
  } deriving (Eq, Show)

data PaymentDirectionError
  = PaymentDirectionUsesSameAccount Account
  deriving (Eq, Show)

mkPaymentDirection
  :: Account
  -> Account
  -> Either PaymentDirectionError PaymentDirection
mkPaymentDirection fromAccount toAccount
  | fromAccount == toAccount =
      Left (PaymentDirectionUsesSameAccount fromAccount)
  | otherwise = Right PaymentDirection
      { paymentDirectionFrom = fromAccount
      , paymentDirectionTo = toAccount
      }

-- | Declarations for the source and destination of one distinct payment.
--
-- The declarations are retained rather than discarded after lookup. A later
-- policy boundary can therefore inspect account types and commodities without
-- repeating registry admission.
data DeclaredPaymentDirection = DeclaredPaymentDirection
  { declaredPaymentSource      :: AccountDeclaration
  , declaredPaymentDestination :: AccountDeclaration
  } deriving (Eq, Show)

data PaymentDirectionAdmissionError
  = UndeclaredPaymentSource Account
  | UndeclaredPaymentDestination Account
  deriving (Eq, Show)

admitPaymentDirection
  :: AccountRegistry
  -> PaymentDirection
  -> Either PaymentDirectionAdmissionError DeclaredPaymentDirection
admitPaymentDirection registry direction =
  DeclaredPaymentDirection
    <$> requireDeclaration UndeclaredPaymentSource source
    <*> requireDeclaration UndeclaredPaymentDestination destination
  where
    source = paymentDirectionFrom direction
    destination = paymentDirectionTo direction

    requireDeclaration missing account =
      case lookupAccountDeclaration account registry of
        Nothing -> Left (missing account)
        Just declaration -> Right declaration

-- | A declared direction proven to be one outgoing household commitment.
--
-- The source must be an Asset and the destination must be an Expense or a
-- Liability. Asset acquisition, transfer, incoming income, and other scheduled
-- meanings require their own explicit Plan kind rather than weakening this one.
newtype DeclaredOutgoingPaymentDirection = DeclaredOutgoingPaymentDirection
  { declaredOutgoingPaymentDirection :: DeclaredPaymentDirection
  } deriving (Eq, Show)

data OutgoingPaymentDirectionAdmissionError
  = OutgoingPaymentSourceMustBeAsset AccountDeclaration
  | OutgoingPaymentDestinationMustBeExpenseOrLiability AccountDeclaration
  deriving (Eq, Show)

admitOutgoingPaymentDirection
  :: DeclaredPaymentDirection
  -> Either OutgoingPaymentDirectionAdmissionError DeclaredOutgoingPaymentDirection
admitOutgoingPaymentDirection direction
  | declaredAccountType source /= Asset =
      Left (OutgoingPaymentSourceMustBeAsset source)
  | declaredAccountType destination `notElem` [Expense, Liability] =
      Left (OutgoingPaymentDestinationMustBeExpenseOrLiability destination)
  | otherwise = Right (DeclaredOutgoingPaymentDirection direction)
  where
    source = declaredPaymentSource direction
    destination = declaredPaymentDestination direction

-- | One sufficiently defined outgoing household commitment.
--
-- Positive quantity and an admitted outgoing direction are supplied as already
-- proven meanings. This constructor therefore owns only Plan-level evidence:
-- durable identity, schedule, memo, amount, and direction.
data CommittedOutgoingPlan = CommittedOutgoingPlan
  { committedPlanId        :: PlanId
  , committedPlanDate      :: Day
  , committedPlanMemo      :: Text
  , committedPlanAmount    :: PositiveAmount
  , committedPlanDirection :: DeclaredOutgoingPaymentDirection
  } deriving (Eq, Show)

data CommittedOutgoingPlanError
  = EmptyCommittedPlanMemo
  | CommittedPlanMemoHasSurroundingWhitespace Text
  | CommittedPlanMemoContainsControlCharacter Text
  deriving (Eq, Show)

mkCommittedOutgoingPlan
  :: PlanId
  -> Day
  -> Text
  -> PositiveAmount
  -> DeclaredOutgoingPaymentDirection
  -> Either CommittedOutgoingPlanError CommittedOutgoingPlan
mkCommittedOutgoingPlan planId plannedDate memo amount direction
  | T.null memo = Left EmptyCommittedPlanMemo
  | T.strip memo /= memo =
      Left (CommittedPlanMemoHasSurroundingWhitespace memo)
  | T.any isControl memo =
      Left (CommittedPlanMemoContainsControlCharacter memo)
  | otherwise = Right CommittedOutgoingPlan
      { committedPlanId = planId
      , committedPlanDate = plannedDate
      , committedPlanMemo = memo
      , committedPlanAmount = amount
      , committedPlanDirection = direction
      }
