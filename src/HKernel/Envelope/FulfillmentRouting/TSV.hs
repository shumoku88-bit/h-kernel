{-# LANGUAGE OverloadedStrings #-}

module HKernel.Envelope.FulfillmentRouting.TSV
  ( FulfillmentRoutingTSVError(..)
  , FulfillmentRoutingTSVErrorReason(..)
  , parseFulfillmentRoutingTSV
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Envelope.FulfillmentRouting
import HKernel.Envelope.Identity (EnvelopeIdError, mkEnvelopeId)
import HKernel.Plan (PlanId, PlanIdError, mkPlanId)

data FulfillmentRoutingTSVError = FulfillmentRoutingTSVError
  { fulfillmentRoutingTSVErrorLine   :: Int
  , fulfillmentRoutingTSVErrorReason :: FulfillmentRoutingTSVErrorReason
  } deriving (Eq, Show)

data FulfillmentRoutingTSVErrorReason
  = MissingFulfillmentRoutingHeader
  | InvalidFulfillmentRoutingHeader Text
  | InvalidFulfillmentRoutingRow Text
  | InvalidFulfillmentRoutingDate Text
  | InvalidFulfillmentRoutingPlan PlanIdError
  | InvalidFulfillmentRoutingKind Text
  | InvalidFulfillmentRoutingEnvelope EnvelopeIdError
  | FulfilledRoutingTargetCannotBeDash
  | NotTargetRoutingTargetMustBeDash Text
  | DuplicateFulfillmentRoutingCoordinate PlanId Day
  deriving (Eq, Show)

-- | Admit one source-local effective-dated PlanId fulfillment history.
--
-- This parser owns syntax only. It does not prove that a PlanId exists across
-- the Plan source boundary; callers apply
-- 'admitFulfillmentRoutingPlanReferences' after source admission. Likewise it
-- does not reinterpret historical Envelope targets through current TOML.
parseFulfillmentRoutingTSV
  :: Text
  -> Either (NonEmpty FulfillmentRoutingTSVError) FulfillmentRoutingHistory
parseFulfillmentRoutingTSV input =
  case meaningfulLines of
    [] -> Left
      (FulfillmentRoutingTSVError 1 MissingFulfillmentRoutingHeader NonEmpty.:| [])
    (headerLine, header) : rows
      | header /= expectedHeader -> Left
          (FulfillmentRoutingTSVError headerLine
            (InvalidFulfillmentRoutingHeader header) NonEmpty.:| [])
      | otherwise ->
          case partitionEithers (map parseLocatedDecision rows) of
            ([], located) -> admitHistory located
            (errors, _) -> Left (NonEmpty.fromList errors)
  where
    meaningfulLines =
      [ (lineNumber, stripCarriageReturn line)
      | (lineNumber, line) <- zip [1..] (T.lines input)
      , let stripped = T.strip line
      , not (T.null stripped)
      , not ("#" `T.isPrefixOf` stripped)
      ]

expectedHeader :: Text
expectedHeader = "effective_from\tplan_id\troute\ttarget\tnote"

parseLocatedDecision
  :: (Int, Text)
  -> Either FulfillmentRoutingTSVError (Int, FulfillmentRoutingDecision)
parseLocatedDecision (lineNumber, line) =
  case T.splitOn "\t" line of
    [effectiveText, planText, routeText, targetText, note] -> do
      effectiveFrom <- parseDate lineNumber effectiveText
      planId <- mapFieldError lineNumber InvalidFulfillmentRoutingPlan
        (mkPlanId planText)
      route <- parseRoute lineNumber routeText targetText
      Right
        ( lineNumber
        , FulfillmentRoutingDecision
            { fulfillmentRoutingEffectiveFrom = effectiveFrom
            , fulfillmentRoutingPlanId = planId
            , fulfillmentRoutingRoute = route
            , fulfillmentRoutingNote = note
            }
        )
    _ -> Left (FulfillmentRoutingTSVError lineNumber
      (InvalidFulfillmentRoutingRow line))

parseDate :: Int -> Text -> Either FulfillmentRoutingTSVError Day
parseDate lineNumber value =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack value) :: Maybe Day of
    Just day -> Right day
    Nothing -> Left (FulfillmentRoutingTSVError lineNumber
      (InvalidFulfillmentRoutingDate value))

parseRoute
  :: Int
  -> Text
  -> Text
  -> Either FulfillmentRoutingTSVError FulfillmentRoute
parseRoute lineNumber routeText targetText = case routeText of
  "fulfills"
    | targetText == "-" -> Left
        (FulfillmentRoutingTSVError lineNumber FulfilledRoutingTargetCannotBeDash)
    | otherwise ->
        FulfillsEnvelope
          <$> mapFieldError lineNumber InvalidFulfillmentRoutingEnvelope
            (mkEnvelopeId targetText)
  "not-target"
    | targetText == "-" -> Right NotFulfillmentTarget
    | otherwise -> Left (FulfillmentRoutingTSVError lineNumber
        (NotTargetRoutingTargetMustBeDash targetText))
  _ -> Left (FulfillmentRoutingTSVError lineNumber
    (InvalidFulfillmentRoutingKind routeText))

admitHistory
  :: [(Int, FulfillmentRoutingDecision)]
  -> Either (NonEmpty FulfillmentRoutingTSVError) FulfillmentRoutingHistory
admitHistory located =
  case mkFulfillmentRoutingHistory (map snd located) of
    Right history -> Right history
    Left errors -> Left (fmap toSourceError errors)
  where
    toSourceError historyError = case historyError of
      DuplicateFulfillmentRoutingDecision planId effectiveFrom ->
        FulfillmentRoutingTSVError
          (duplicateLine planId effectiveFrom located)
          (DuplicateFulfillmentRoutingCoordinate planId effectiveFrom)

    duplicateLine planId effectiveFrom values =
      maximum
        (1 :
          [ lineNumber
          | (lineNumber, decision) <- values
          , fulfillmentRoutingPlanId decision == planId
          , fulfillmentRoutingEffectiveFrom decision == effectiveFrom
          ])

mapFieldError
  :: Int
  -> (error -> FulfillmentRoutingTSVErrorReason)
  -> Either error value
  -> Either FulfillmentRoutingTSVError value
mapFieldError lineNumber wrap result = case result of
  Left err -> Left (FulfillmentRoutingTSVError lineNumber (wrap err))
  Right value -> Right value

stripCarriageReturn :: Text -> Text
stripCarriageReturn = T.dropWhileEnd (== '\r')
