-- | Explicit evidence that part of one outgoing Plan is already reserved.
--
-- This module validates only the reservation relation. It does not decide which
-- Plans belong in Daily Target, where reserved funds live, or how Backing is
-- computed. A source boundary supplies durable reservation identity, a Plan
-- reference, and a positive exact amount.
module HKernel.Plan.Reservation
  ( ReservationId
  , ReservationIdError(..)
  , mkReservationId
  , reservationIdText
  , PlanReservationDeclaration
  , declarePlanReservation
  , declaredReservationId
  , declaredReservationPlanId
  , declaredReservationAmount
  , PlanReservationEvidence
  , reservationEvidenceId
  , reservationEvidencePlan
  , reservationEvidenceAmount
  , PlanReservationError(..)
  , resolvePlanReservationEvidence
  ) where

import Data.Char (isControl, isSpace)
import Data.Either (partitionEithers)
import qualified Data.Foldable as Foldable
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Money
  ( Amount
  , Commodity
  , amountCommodity
  , amountQuantity
  )
import HKernel.Plan
  ( CommittedOutgoingPlan
  , PlanId
  , PositiveAmount
  , committedPlanAmount
  , committedPlanId
  , positiveAmountValue
  )

-- | Durable identity for one reservation relation.
newtype ReservationId = ReservationId
  { reservationIdText :: Text
  } deriving (Eq, Ord, Show)

data ReservationIdError
  = EmptyReservationId
  | ReservationIdHasSurroundingWhitespace Text
  | ReservationIdContainsControlCharacter Text
  | ReservationIdContainsWhitespace Text
  deriving (Eq, Show)

mkReservationId :: Text -> Either ReservationIdError ReservationId
mkReservationId value
  | T.null value = Left EmptyReservationId
  | T.strip value /= value =
      Left (ReservationIdHasSurroundingWhitespace value)
  | T.any isControl value =
      Left (ReservationIdContainsControlCharacter value)
  | T.any isSpace value =
      Left (ReservationIdContainsWhitespace value)
  | otherwise = Right (ReservationId value)

-- | Source declaration that one positive amount is already reserved for one
-- outgoing Plan. It is not yet proof that the Plan exists or that the amount is
-- compatible with it.
data PlanReservationDeclaration = PlanReservationDeclaration
  { declaredReservationId     :: ReservationId
  , declaredReservationPlanId :: PlanId
  , declaredReservationAmount :: PositiveAmount
  } deriving (Eq, Show)

declarePlanReservation
  :: ReservationId
  -> PlanId
  -> PositiveAmount
  -> PlanReservationDeclaration
declarePlanReservation = PlanReservationDeclaration

-- | Rebuildable proof that one reservation resolves to an admitted Plan, uses
-- the same Commodity, and does not exceed the Plan amount.
data PlanReservationEvidence = PlanReservationEvidence
  { reservationEvidenceId     :: ReservationId
  , reservationEvidencePlan   :: CommittedOutgoingPlan
  , reservationEvidenceAmount :: PositiveAmount
  } deriving (Eq, Show)

data PlanReservationError
  = DuplicateReservationPlanId PlanId
  | DuplicateReservationId ReservationId
  | UnknownReservationPlanReference ReservationId PlanId
  | PlanReservedByMultipleReservations PlanId (NonEmpty ReservationId)
  | ReservationCommodityMismatch
      ReservationId PlanId Commodity Commodity
  | ReservationExceedsPlanAmount ReservationId PlanId Amount Amount
  deriving (Eq, Show)

-- | Resolve reservation declarations without guessing or clamping.
--
-- Output order follows declaration order. Duplicate Plan facts, duplicate
-- reservation identities, more than one reservation declaration for one Plan,
-- unknown Plan references, cross-Commodity amounts, and over-reservation are
-- rejected rather than silently selecting, converting, or truncating values.
resolvePlanReservationEvidence
  :: (Foldable planCollection, Foldable declarationCollection)
  => planCollection CommittedOutgoingPlan
  -> declarationCollection PlanReservationDeclaration
  -> Either (NonEmpty PlanReservationError) [PlanReservationEvidence]
resolvePlanReservationEvidence plans declarations =
  case NonEmpty.nonEmpty errors of
    Just reservationErrors -> Left reservationErrors
    Nothing -> Right resolvedEvidence
  where
    planList = Foldable.toList plans
    declarationList = Foldable.toList declarations

    planById = Map.fromList
      [ (committedPlanId plan, plan)
      | plan <- planList
      ]

    (referenceErrors, resolvedEvidence) =
      partitionEithers (map resolveDeclaration declarationList)

    errors =
      duplicatePlanErrors
        ++ duplicateReservationErrors
        ++ referenceErrors
        ++ multipleReservationErrors

    duplicatePlanErrors =
      [ DuplicateReservationPlanId planId
      | planId <- duplicateKeys committedPlanId planList
      ]

    duplicateReservationErrors =
      [ DuplicateReservationId reservationId
      | reservationId <- duplicateKeys declaredReservationId declarationList
      ]

    multipleReservationErrors =
      [ PlanReservedByMultipleReservations planId reservationIds
      | (planId, reservationIdSet) <- Map.toAscList reservationIdsByPlan
      , Map.member planId planById
      , let ids = Set.toAscList reservationIdSet
      , Just reservationIds <- [NonEmpty.nonEmpty ids]
      , NonEmpty.length reservationIds > 1
      ]

    reservationIdsByPlan = Map.fromListWith Set.union
      [ ( declaredReservationPlanId declaration
        , Set.singleton (declaredReservationId declaration)
        )
      | declaration <- declarationList
      ]

    resolveDeclaration declaration = case Map.lookup planId planById of
      Nothing -> Left (UnknownReservationPlanReference reservationId planId)
      Just plan ->
        let planAmount = positiveAmountValue (committedPlanAmount plan)
            reservationAmount =
              positiveAmountValue (declaredReservationAmount declaration)
            planCommodity = amountCommodity planAmount
            reservationCommodity = amountCommodity reservationAmount
        in if reservationCommodity /= planCommodity
          then Left (ReservationCommodityMismatch
            reservationId planId planCommodity reservationCommodity)
          else if amountQuantity reservationAmount > amountQuantity planAmount
            then Left (ReservationExceedsPlanAmount
              reservationId planId planAmount reservationAmount)
            else Right PlanReservationEvidence
              { reservationEvidenceId = reservationId
              , reservationEvidencePlan = plan
              , reservationEvidenceAmount = declaredReservationAmount declaration
              }
      where
        reservationId = declaredReservationId declaration
        planId = declaredReservationPlanId declaration

    duplicateKeys keyOf values =
      [ key
      | (key, count) <- Map.toAscList
          (Map.fromListWith (+) [(keyOf value, 1 :: Int) | value <- values])
      , count > 1
      ]
