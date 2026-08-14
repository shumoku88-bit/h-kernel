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
  | DuplicateInitialExpenseRoutingCoordinate Account
  | DuplicateExpenseRoutingCoordinate Account Day
  deriving (Eq, Show)

data LocatedExpenseRoutingDecision
  = LocatedInitial Int InitialExpenseRoutingDecision
  | LocatedDated Int ExpenseRoutingDecision

-- | Admit one source-local Expense routing history.
--
-- @effective_from@ accepts either an ISO household day or the literal
-- @initial@. The latter means the route is already effective before the bounded
-- history being observed; it is deliberately not converted into an invented
-- date. Cross-source Account/Envelope reference checks remain a separate
-- admission step.
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
  -> Either ExpenseRoutingTSVError LocatedExpenseRoutingDecision
parseLocatedDecision (lineNumber, line) =
  case T.splitOn "\t" line of
    [effectiveText, accountText, routeText, targetText, note] -> do
      account <- mapFieldError lineNumber InvalidExpenseRoutingAccount
        (mkAccount accountText)
      route <- parseRoute lineNumber routeText targetText
      if effectiveText == "initial"
        then Right
          (LocatedInitial lineNumber InitialExpenseRoutingDecision
            { initialExpenseRoutingAccount = account
            , initialExpenseRoutingRoute = route
            , initialExpenseRoutingNote = note
            })
        else do
          effectiveFrom <- parseDate lineNumber effectiveText
          Right
            (LocatedDated lineNumber ExpenseRoutingDecision
              { expenseRoutingEffectiveFrom = effectiveFrom
              , expenseRoutingAccount = account
              , expenseRoutingRoute = route
              , expenseRoutingNote = note
              })
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
  :: [LocatedExpenseRoutingDecision]
  -> Either (NonEmpty ExpenseRoutingTSVError) ExpenseRoutingHistory
admitHistory located =
  case mkExpenseRoutingHistoryWithInitial initialDecisions datedDecisions of
    Right history -> Right history
    Left errors -> Left (fmap toSourceError errors)
  where
    initialDecisions =
      [ decision
      | LocatedInitial _ decision <- located
      ]
    datedDecisions =
      [ decision
      | LocatedDated _ decision <- located
      ]

    toSourceError historyError = case historyError of
      DuplicateInitialExpenseRoutingDecision account ->
        ExpenseRoutingTSVError
          (duplicateInitialLine account located)
          (DuplicateInitialExpenseRoutingCoordinate account)
      DuplicateExpenseRoutingDecision account effectiveFrom ->
        ExpenseRoutingTSVError
          (duplicateDatedLine account effectiveFrom located)
          (DuplicateExpenseRoutingCoordinate account effectiveFrom)

    duplicateInitialLine account values =
      maximum
        (1 :
          [ lineNumber
          | LocatedInitial lineNumber decision <- values
          , initialExpenseRoutingAccount decision == account
          ])

    duplicateDatedLine account effectiveFrom values =
      maximum
        (1 :
          [ lineNumber
          | LocatedDated lineNumber decision <- values
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
