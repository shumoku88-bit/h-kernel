{-# LANGUAGE OverloadedStrings #-}

module HKernel.Envelope.ExpenseRouting.TSV
  ( ExpenseRoutingTSVError(..)
  , ExpenseRoutingTSVErrorReason(..)
  , parseExpenseRoutingTSV
  ) where

import Data.Either (partitionEithers)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import HKernel.Account (Account, AccountError, mkAccount)
import HKernel.Envelope.ExpenseRouting
import HKernel.Envelope.Identity (EnvelopeIdError, mkEnvelopeId)

data ExpenseRoutingTSVError = ExpenseRoutingTSVError
  { expenseRoutingTSVErrorLine   :: Int
  , expenseRoutingTSVErrorReason :: ExpenseRoutingTSVErrorReason
  } deriving (Eq, Show)

data ExpenseRoutingTSVErrorReason
  = MissingExpenseRoutingHeader
  | InvalidExpenseRoutingHeader Text
  | InvalidExpenseRoutingRow Text
  | InvalidExpenseRoutingDate Text
  | InvalidExpenseRoutingAccount AccountError
  | InvalidExpenseRoutingKind Text
  | InvalidExpenseRoutingEnvelope EnvelopeIdError
  | ManagedExpenseRoutingTargetCannotBeDash
  | UnmanagedExpenseRoutingTargetMustBeDash Text
  | DuplicateExpenseRoutingCoordinate Account Day
  deriving (Eq, Show)

parseExpenseRoutingTSV
  :: Text
  -> Either (NonEmpty ExpenseRoutingTSVError) ExpenseRoutingHistory
parseExpenseRoutingTSV input =
  case meaningfulLines of
    [] -> Left
      (ExpenseRoutingTSVError 1 MissingExpenseRoutingHeader NonEmpty.:| [])
    (headerLine, header) : rows
      | header /= expectedHeader -> Left
          (ExpenseRoutingTSVError headerLine
            (InvalidExpenseRoutingHeader header) NonEmpty.:| [])
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
expectedHeader = "effective_from\texpense_account\troute\ttarget\tnote"

parseLocatedDecision
  :: (Int, Text)
  -> Either ExpenseRoutingTSVError (Int, ExpenseRoutingDecision)
parseLocatedDecision (lineNumber, line) =
  case T.splitOn "\t" line of
    [effectiveText, accountText, routeText, targetText, note] -> do
      effectiveFrom <- parseDate lineNumber effectiveText
      account <- mapFieldError lineNumber InvalidExpenseRoutingAccount
        (mkAccount accountText)
      route <- parseRoute lineNumber routeText targetText
      Right
        ( lineNumber
        , ExpenseRoutingDecision
            { expenseRoutingEffectiveFrom = effectiveFrom
            , expenseRoutingAccount = account
            , expenseRoutingRoute = route
            , expenseRoutingNote = note
            }
        )
    _ -> Left (ExpenseRoutingTSVError lineNumber
      (InvalidExpenseRoutingRow line))

parseDate :: Int -> Text -> Either ExpenseRoutingTSVError Day
parseDate lineNumber value =
  case parseTimeM True defaultTimeLocale "%F" (T.unpack value) :: Maybe Day of
    Just day -> Right day
    Nothing -> Left (ExpenseRoutingTSVError lineNumber
      (InvalidExpenseRoutingDate value))

parseRoute
  :: Int
  -> Text
  -> Text
  -> Either ExpenseRoutingTSVError ExpenseRoute
parseRoute lineNumber routeText targetText = case routeText of
  "managed"
    | targetText == "-" -> Left
        (ExpenseRoutingTSVError lineNumber ManagedExpenseRoutingTargetCannotBeDash)
    | otherwise ->
        ManagedByEnvelope
          <$> mapFieldError lineNumber InvalidExpenseRoutingEnvelope
            (mkEnvelopeId targetText)
  "unmanaged"
    | targetText == "-" -> Right NotEnvelopeManaged
    | otherwise -> Left (ExpenseRoutingTSVError lineNumber
        (UnmanagedExpenseRoutingTargetMustBeDash targetText))
  _ -> Left (ExpenseRoutingTSVError lineNumber
    (InvalidExpenseRoutingKind routeText))

admitHistory
  :: [(Int, ExpenseRoutingDecision)]
  -> Either (NonEmpty ExpenseRoutingTSVError) ExpenseRoutingHistory
admitHistory located =
  case mkExpenseRoutingHistory (map snd located) of
    Right history -> Right history
    Left errors -> Left (fmap toSourceError errors)
  where
    toSourceError historyError = case historyError of
      DuplicateExpenseRoutingDecision account effectiveFrom ->
        ExpenseRoutingTSVError
          (duplicateLine account effectiveFrom located)
          (DuplicateExpenseRoutingCoordinate account effectiveFrom)

    duplicateLine account effectiveFrom values =
      maximum
        (1 :
          [ lineNumber
          | (lineNumber, decision) <- values
          , expenseRoutingAccount decision == account
          , expenseRoutingEffectiveFrom decision == effectiveFrom
          ])

mapFieldError
  :: Int
  -> (error -> ExpenseRoutingTSVErrorReason)
  -> Either error value
  -> Either ExpenseRoutingTSVError value
mapFieldError lineNumber wrap result = case result of
  Left err -> Left (ExpenseRoutingTSVError lineNumber (wrap err))
  Right value -> Right value

stripCarriageReturn :: Text -> Text
stripCarriageReturn = T.dropWhileEnd (== '\r')
