{-# LANGUAGE OverloadedStrings #-}

module HKernel.Envelope.EntitlementTSV
  ( EnvelopeEntitlementDateField(..)
  , EnvelopeEntitlementTSVError(..)
  , EnvelopeEntitlementTSVErrorReason(..)
  , parseEnvelopeEntitlementTSV
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Envelope.EntitlementHistory
import HKernel.Envelope.EntitlementTransfer
import HKernel.Envelope.Identity
import HKernel.Money
import HKernel.Period

data EnvelopeEntitlementDateField
  = EntitlementDate
  | EntitlementPeriodStart
  | EntitlementPeriodEndExclusive
  deriving (Eq, Ord, Show)

data EnvelopeEntitlementTSVError = EnvelopeEntitlementTSVError
  { envelopeEntitlementTSVErrorLine :: Int
  , envelopeEntitlementTSVErrorReason :: EnvelopeEntitlementTSVErrorReason
  } deriving (Eq, Show)

data EnvelopeEntitlementTSVErrorReason
  = MissingEnvelopeEntitlementHeader
  | InvalidEnvelopeEntitlementHeader Text
  | InvalidEnvelopeEntitlementRow Text
  | InvalidEnvelopeEntitlementDate EnvelopeEntitlementDateField Text
  | InvalidEnvelopeEntitlementPeriod PeriodError
  | InvalidEnvelopeEndpoint Text EnvelopeIdError
  | InvalidEnvelopeEntitlementQuantity QuantityError
  | InvalidEnvelopeEntitlementCommodity CommodityError
  | InvalidEnvelopeEntitlementTransfer EnvelopeEntitlementTransferError
  | InvalidEnvelopeEntitlementHistory EnvelopeEntitlementHistoryError
  deriving (Eq, Show)

parseEnvelopeEntitlementTSV
  :: Text
  -> Either (NonEmpty EnvelopeEntitlementTSVError) EnvelopeEntitlementHistory
parseEnvelopeEntitlementTSV input =
  case meaningfulLines of
    [] -> Left
      (EnvelopeEntitlementTSVError 1 MissingEnvelopeEntitlementHeader
        NonEmpty.:| [])
    (headerLine, header) : rows
      | header /= expectedHeader ->
          Left
            (EnvelopeEntitlementTSVError headerLine
              (InvalidEnvelopeEntitlementHeader header)
              NonEmpty.:| [])
      | otherwise ->
          case partitionEithers (map parseLocatedRow rows) of
            ([], locatedTransfers) -> admitHistory locatedTransfers
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
expectedHeader =
  "date\tperiod_start\tperiod_end_exclusive\tfrom\tto\tquantity\tcommodity\tnote"

parseLocatedRow
  :: (Int, Text)
  -> Either EnvelopeEntitlementTSVError (Int, EnvelopeEntitlementTransfer)
parseLocatedRow (lineNumber, line) =
  case T.splitOn "\t" line of
    [ dateText
      , startText
      , endText
      , fromText
      , toText
      , quantityText
      , commodityText
      , note
      ] -> do
        effectiveDay <- parseDate lineNumber EntitlementDate dateText
        periodStartDay <- parseDate lineNumber EntitlementPeriodStart startText
        periodEndDay <- parseDate lineNumber EntitlementPeriodEndExclusive endText
        period <- mapFieldError lineNumber InvalidEnvelopeEntitlementPeriod
          (mkPeriod periodStartDay periodEndDay)
        fromEndpoint <- parseEndpoint lineNumber fromText
        toEndpoint <- parseEndpoint lineNumber toText
        quantity <- mapFieldError lineNumber InvalidEnvelopeEntitlementQuantity
          (parseQuantity quantityText)
        commodity <- mapFieldError lineNumber InvalidEnvelopeEntitlementCommodity
          (mkCommodity commodityText)
        transfer <- mapFieldError lineNumber InvalidEnvelopeEntitlementTransfer
          (mkEnvelopeEntitlementTransfer
            effectiveDay
            period
            fromEndpoint
            toEndpoint
            (mkAmount commodity quantity)
            note)
        Right (lineNumber, transfer)
    _ -> Left (EnvelopeEntitlementTSVError lineNumber
      (InvalidEnvelopeEntitlementRow line))

parseDate
  :: Int
  -> EnvelopeEntitlementDateField
  -> Text
  -> Either EnvelopeEntitlementTSVError Day
parseDate lineNumber field value =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack value) :: Maybe Day of
    Just day -> Right day
    Nothing -> Left (EnvelopeEntitlementTSVError lineNumber
      (InvalidEnvelopeEntitlementDate field value))

parseEndpoint
  :: Int
  -> Text
  -> Either EnvelopeEntitlementTSVError EnvelopeEndpoint
parseEndpoint _ "unallocated" = Right Unallocated
parseEndpoint lineNumber value =
  case mkEnvelopeId value of
    Left err -> Left (EnvelopeEntitlementTSVError lineNumber
      (InvalidEnvelopeEndpoint value err))
    Right envelope -> Right (Spendable envelope)

admitHistory
  :: [(Int, EnvelopeEntitlementTransfer)]
  -> Either (NonEmpty EnvelopeEntitlementTSVError) EnvelopeEntitlementHistory
admitHistory locatedTransfers =
  case mkEnvelopeEntitlementHistory (map snd locatedTransfers) of
    Right history -> Right history
    Left errors -> Left (fmap toSourceError errors)
  where
    toSourceError historyError = EnvelopeEntitlementTSVError
      (historyErrorLine locatedTransfers historyError)
      (InvalidEnvelopeEntitlementHistory historyError)

historyErrorLine
  :: [(Int, EnvelopeEntitlementTransfer)]
  -> EnvelopeEntitlementHistoryError
  -> Int
historyErrorLine locatedTransfers historyError =
  case historyError of
    EnvelopeEntitlementBecameNegative period envelope commodity effectiveDay _ ->
      maximum
        (1 :
          [ lineNumber
          | (lineNumber, transfer) <- locatedTransfers
          , entitlementTransferPeriod transfer == period
          , entitlementTransferDate transfer == effectiveDay
          , amountCommodity (entitlementTransferAmount transfer) == commodity
          , endpointNames envelope (entitlementTransferFrom transfer)
              || endpointNames envelope (entitlementTransferTo transfer)
          ])

endpointNames :: EnvelopeId -> EnvelopeEndpoint -> Bool
endpointNames expected endpoint = case endpoint of
  Unallocated -> False
  Spendable actual -> actual == expected

mapFieldError
  :: Int
  -> (error -> EnvelopeEntitlementTSVErrorReason)
  -> Either error value
  -> Either EnvelopeEntitlementTSVError value
mapFieldError lineNumber wrap result = case result of
  Left err -> Left (EnvelopeEntitlementTSVError lineNumber (wrap err))
  Right value -> Right value

stripCarriageReturn :: Text -> Text
stripCarriageReturn = T.dropWhileEnd (== '\r')
