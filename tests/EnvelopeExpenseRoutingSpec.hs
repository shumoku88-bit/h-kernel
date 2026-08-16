{-# LANGUAGE OverloadedStrings #-}

module EnvelopeExpenseRoutingSpec (main) where

import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day, fromGregorian)
import HKernel.Account
  ( Account
  , AccountType(..)
  , declareAccount
  , emptyAccountRegistry
  , mkAccount
  , registerAccount
  )
import HKernel.Envelope.ExpenseRouting
import HKernel.Envelope.ExpenseRouting.TSV
import HKernel.Envelope.Identity
  ( EnvelopeId
  , mkEnvelopeId
  , mkEnvelopeRegistry
  )
import System.Exit (exitFailure)

main :: IO ()
main = do
  historyLaws
  resolverLaws
  tsvLaws
  referenceAdmissionLaws

historyLaws :: IO ()
historyLaws = do
  let foodAccount = account "expenses:食費"
      travelAccount = account "expenses:travel-jpy"
      food = envelope "食費"
      general = envelope "一般生活"
      initial = decision (day 1) foodAccount (ManagedByEnvelope food) "initial"
      moved = decision (day 10) foodAccount (ManagedByEnvelope general) "changed intent"
      unmanaged = decision (day 20) foodAccount NotEnvelopeManaged "stop envelope management"
      travel = decision (day 10) travelAccount NotEnvelopeManaged "explicitly outside"
      sourceOrder = [unmanaged, initial, travel, moved]
      history = mustRight (mkExpenseRoutingHistory sourceOrder)

  equal "routing history preserves source order as provenance"
    sourceOrder
    (expenseRoutingHistoryDecisions history)
  equal "missing history remains attention before first decision"
    Nothing
    (expenseRouteAt (fromGregorian 2026 7 31) foodAccount history)
  equal "first effective route applies on its day"
    (Just (ManagedByEnvelope food))
    (expenseRouteAt (day 1) foodAccount history)
  equal "later effective route changes current intent"
    (Just (ManagedByEnvelope general))
    (expenseRouteAt (day 15) foodAccount history)
  equal "explicit unmanaged differs from missing routing"
    (Just NotEnvelopeManaged)
    (expenseRouteAt (day 20) foodAccount history)
  equal "independent Expense account has its own route"
    (Just NotEnvelopeManaged)
    (expenseRouteAt (day 10) travelAccount history)
  left "same Account/day routing coordinate is ambiguous"
    (mkExpenseRoutingHistory
      [ initial
      , decision (day 1) foodAccount (ManagedByEnvelope general) "same day"
      ])
  right "same route may be reaffirmed on a later day"
    (mkExpenseRoutingHistory
      [ initial
      , decision (day 2) foodAccount (ManagedByEnvelope food) "reaffirm"
      ])

resolverLaws :: IO ()
resolverLaws = do
  let foodAccount = account "expenses:食費"
      travelAccount = account "expenses:travel-jpy"
      food = envelope "食費"
      general = envelope "一般生活"
      initial = decision (day 1) foodAccount (ManagedByEnvelope food) "initial"
      moved = decision (day 10) foodAccount (ManagedByEnvelope general) "changed intent"
      unmanaged = decision (day 20) foodAccount NotEnvelopeManaged "stop envelope management"
      travel = decision (day 10) travelAccount NotEnvelopeManaged "explicitly outside"
      history = mustRight (mkExpenseRoutingHistory [unmanaged, initial, travel, moved])
      resolver = expenseRoutingResolver history

  equal "resolver projects missing history before first decision"
    Nothing
    (resolveExpenseRoute resolver (fromGregorian 2026 7 31) foodAccount)
  equal "resolver projects initial effective route"
    (Just (ManagedByEnvelope food))
    (resolveExpenseRoute resolver (day 1) foodAccount)
  equal "resolver projects changed intent route"
    (Just (ManagedByEnvelope general))
    (resolveExpenseRoute resolver (day 15) foodAccount)
  equal "resolver projects explicit unmanaged route"
    (Just NotEnvelopeManaged)
    (resolveExpenseRoute resolver (day 20) foodAccount)
  equal "resolver projects independent account route"
    (Just NotEnvelopeManaged)
    (resolveExpenseRoute resolver (day 10) travelAccount)

tsvLaws :: IO ()
tsvLaws = do
  let source = T.unlines
        [ header
        , "# effective date, not source order, governs"
        , "2026-08-20\texpenses:食費\tunmanaged\t-\tstop"
        , "2026-08-01\texpenses:食費\tmanaged\t食費\tinitial"
        , "2026-08-10\texpenses:食費\tmanaged\t一般生活\tchange"
        , "2026-08-01\texpenses:future\tmanaged\tfuture-envelope\tsyntax only"
        ]
      history = mustRight (parseExpenseRoutingTSV source)
      foodAccount = account "expenses:食費"
      futureAccount = account "expenses:future"

  equal "TSV admits historical route by effective date"
    (Just (ManagedByEnvelope (envelope "食費")))
    (expenseRouteAt (day 5) foodAccount history)
  equal "later TSV decision changes route"
    (Just (ManagedByEnvelope (envelope "一般生活")))
    (expenseRouteAt (day 15) foodAccount history)
  equal "unmanaged is explicit after its effective date"
    (Just NotEnvelopeManaged)
    (expenseRouteAt (day 20) foodAccount history)
  equal "source-local admission does not require current Envelope policy"
    (Just (ManagedByEnvelope (envelope "future-envelope")))
    (expenseRouteAt (day 1) futureAccount history)

  right "CRLF input is admitted"
    (parseExpenseRoutingTSV
      (T.replace "\n" "\r\n"
        (header <> "\n2026-08-01\texpenses:食費\tmanaged\t食費\tcrlf\n")))

  assertSingleError "missing header points to physical line 1"
    (\err -> expenseRoutingTSVErrorLine err == 1
      && expenseRoutingTSVErrorReason err == MissingExpenseRoutingHeader)
    (parseExpenseRoutingTSV "")

  assertSingleError "row width is exact"
    (\err -> expenseRoutingTSVErrorLine err == 2
      && case expenseRoutingTSVErrorReason err of
        InvalidExpenseRoutingRow _ -> True
        _ -> False)
    (parseExpenseRoutingTSV (T.unlines
      [ header
      , "2026-08-01\texpenses:食費\tmanaged\t食費\tnote\textra"
      ]))

  assertSingleError "unknown route kind fails closed"
    (\err -> case expenseRoutingTSVErrorReason err of
      InvalidExpenseRoutingKind "maybe" -> True
      _ -> False)
    (parseExpenseRoutingTSV (T.unlines
      [ header
      , "2026-08-01\texpenses:食費\tmaybe\t食費\tbad"
      ]))

  assertSingleError "managed route cannot use unmanaged sentinel"
    (\err -> expenseRoutingTSVErrorReason err
      == ManagedExpenseRoutingTargetCannotBeDash)
    (parseExpenseRoutingTSV (T.unlines
      [ header
      , "2026-08-01\texpenses:食費\tmanaged\t-\tbad"
      ]))

  assertSingleError "unmanaged route requires dash target"
    (\err -> case expenseRoutingTSVErrorReason err of
      UnmanagedExpenseRoutingTargetMustBeDash "食費" -> True
      _ -> False)
    (parseExpenseRoutingTSV (T.unlines
      [ header
      , "2026-08-01\texpenses:食費\tunmanaged\t食費\tbad"
      ]))

  assertSingleError "duplicate Account/day points at later physical row"
    (\err -> expenseRoutingTSVErrorLine err == 3
      && case expenseRoutingTSVErrorReason err of
        DuplicateExpenseRoutingCoordinate actualAccount actualDay ->
          actualAccount == foodAccount && actualDay == day 1
        _ -> False)
    (parseExpenseRoutingTSV (T.unlines
      [ header
      , "2026-08-01\texpenses:食費\tmanaged\t食費\tfirst"
      , "2026-08-01\texpenses:食費\tunmanaged\t-\tsecond"
      ]))

referenceAdmissionLaws :: IO ()
referenceAdmissionLaws = do
  let foodExpense = account "expenses:食費"
      travelExpense = account "expenses:travel-jpy"
      bankAsset = account "assets:bank"
      salaryIncome = account "income:salary"
      undeclaredAccount = account "expenses:undeclared"

      foodEnvelope = envelope "食費"
      historicalEnvelope = envelope "historical-retired"
      missingEnvelope = envelope "missing-envelope"

      accountRegistry = mustRight
        ( registerAccount (declareAccount foodExpense Expense)
        =<< registerAccount (declareAccount travelExpense Expense)
        =<< registerAccount (declareAccount bankAsset Asset)
        =<< registerAccount (declareAccount salaryIncome Income) emptyAccountRegistry
        )

      envelopeRegistry = mustRight
        (mkEnvelopeRegistry [foodEnvelope, historicalEnvelope])

      validManaged = mustRight (mkExpenseRoutingHistory
        [ decision (day 1) foodExpense (ManagedByEnvelope foodEnvelope) "valid managed"
        ])
      validHistorical = mustRight (mkExpenseRoutingHistory
        [ decision (day 2) foodExpense (ManagedByEnvelope historicalEnvelope) "historical target"
        ])
      validUnmanaged = mustRight (mkExpenseRoutingHistory
        [ decision (day 3) travelExpense NotEnvelopeManaged "valid unmanaged"
        ])
      unknownEnvelopeHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 4) foodExpense (ManagedByEnvelope missingEnvelope) "unknown envelope"
        ])
      undeclaredAccountHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 5) undeclaredAccount (ManagedByEnvelope foodEnvelope) "undeclared account"
        ])
      assetAccountHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 6) bankAsset (ManagedByEnvelope foodEnvelope) "asset account"
        ])
      incomeAccountHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 7) salaryIncome (ManagedByEnvelope foodEnvelope) "income account"
        ])
      unmanagedUndeclaredHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 8) undeclaredAccount NotEnvelopeManaged "unmanaged undeclared"
        ])
      unmanagedNonExpenseHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 9) bankAsset NotEnvelopeManaged "unmanaged asset"
        ])
      doublyDanglingHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 10) undeclaredAccount (ManagedByEnvelope missingEnvelope) "undeclared and unknown envelope"
        ])
      nonExpenseAndUnknownEnvelopeHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 11) bankAsset (ManagedByEnvelope missingEnvelope) "non-expense and unknown envelope"
        ])
      orderedMultiErrorHistory = mustRight (mkExpenseRoutingHistory
        [ decision (day 1) undeclaredAccount (ManagedByEnvelope missingEnvelope) "first error pair"
        , decision (day 2) bankAsset NotEnvelopeManaged "second error"
        ])

  right "admitted Expense Account and registered Envelope accepts"
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry validManaged)
  right "historical registered Envelope accepts regardless of current policy"
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry validHistorical)
  right "admitted Expense Account with NotEnvelopeManaged accepts without Envelope target check"
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry validUnmanaged)

  equal "unknown Envelope target fails closed"
    (Left (UnknownExpenseRoutingEnvelope foodExpense (day 4) missingEnvelope NonEmpty.:| []))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry unknownEnvelopeHistory)

  equal "undeclared routing Account fails closed"
    (Left (UnknownExpenseRoutingAccount undeclaredAccount (day 5) NonEmpty.:| []))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry undeclaredAccountHistory)

  equal "Asset routing Account fails with actual type"
    (Left (ExpenseRoutingAccountNotExpense bankAsset (day 6) Asset NonEmpty.:| []))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry assetAccountHistory)

  equal "Income routing Account fails with actual type"
    (Left (ExpenseRoutingAccountNotExpense salaryIncome (day 7) Income NonEmpty.:| []))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry incomeAccountHistory)

  equal "unmanaged route still requires declared Account"
    (Left (UnknownExpenseRoutingAccount undeclaredAccount (day 8) NonEmpty.:| []))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry unmanagedUndeclaredHistory)

  equal "unmanaged route still requires Expense type"
    (Left (ExpenseRoutingAccountNotExpense bankAsset (day 9) Asset NonEmpty.:| []))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry unmanagedNonExpenseHistory)

  equal "one decision with independent invalid references accumulates errors deterministically"
    (Left
      ( UnknownExpenseRoutingAccount undeclaredAccount (day 10)
        NonEmpty.:|
          [ UnknownExpenseRoutingEnvelope undeclaredAccount (day 10) missingEnvelope
          ]
      ))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry doublyDanglingHistory)

  equal "one non-Expense decision with unknown Envelope accumulates both errors"
    (Left
      ( ExpenseRoutingAccountNotExpense bankAsset (day 11) Asset
        NonEmpty.:|
          [ UnknownExpenseRoutingEnvelope bankAsset (day 11) missingEnvelope
          ]
      ))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry nonExpenseAndUnknownEnvelopeHistory)

  equal "multiple decisions accumulate all errors in source order"
    (Left
      ( UnknownExpenseRoutingAccount undeclaredAccount (day 1)
        NonEmpty.:|
          [ UnknownExpenseRoutingEnvelope undeclaredAccount (day 1) missingEnvelope
          , ExpenseRoutingAccountNotExpense bankAsset (day 2) Asset
          ]
      ))
    (admitExpenseRoutingReferences accountRegistry envelopeRegistry orderedMultiErrorHistory)

header :: Text
header = "effective_from\texpense_account\troute\ttarget\tnote"

day :: Int -> Day
day = fromGregorian 2026 8

account :: Text -> Account
account = mustRight . mkAccount

envelope :: Text -> EnvelopeId
envelope = mustRight . mkEnvelopeId

decision :: Day -> Account -> ExpenseRoute -> Text -> ExpenseRoutingDecision
decision effectiveFrom expenseAccount route note = ExpenseRoutingDecision
  { expenseRoutingEffectiveFrom = effectiveFrom
  , expenseRoutingAccount = expenseAccount
  , expenseRoutingRoute = route
  , expenseRoutingNote = note
  }

assertSingleError
  :: Show value
  => String
  -> (ExpenseRoutingTSVError -> Bool)
  -> Either (NonEmpty.NonEmpty ExpenseRoutingTSVError) value
  -> IO ()
assertSingleError label predicate result = case result of
  Left errors -> case NonEmpty.toList errors of
    [err] | predicate err -> pass label
    unexpected -> failTest label ("unexpected errors: " ++ show unexpected)
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

left :: Show value => String -> Either error value -> IO ()
left label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

right :: Show error => String -> Either error value -> IO ()
right label result = case result of
  Right _ -> pass label
  Left err -> failTest label ("unexpectedly rejected: " ++ show err)

equal :: (Eq value, Show value) => String -> value -> value -> IO ()
equal label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

mustRight :: Show error => Either error value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error (show err)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
