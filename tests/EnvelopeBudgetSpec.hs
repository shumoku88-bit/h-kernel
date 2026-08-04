{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Engine (mkDateRange)
import HKernel.Envelope
import HKernel.Envelope.Render
import HKernel.Journal (journalFromTransactions, parseJournal)
import HKernel.Ledger
import HKernel.Money
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizePolicyErrors
  characterizeEnvelopeBudget
  characterizePolicyValidation
  characterizeUnclassifiedEvidence

characterizePolicyErrors :: IO ()
characterizePolicyErrors = do
  let everyday = mustRight (mkEnvelopeName "Everyday")
      reasons = case parseEnvelopePolicy invalidPolicyInput of
        Left errors -> map envelopePolicyErrorReason (NonEmpty.toList errors)
        Right _ -> []
  assertEqual
    "policy rejects duplicate allocation coordinates"
    True
    (any isDuplicateAllocation reasons)
  assertEqual
    "policy rejects duplicate account assignments"
    True
    (any isDuplicateAssignment reasons)
  assertEqual
    "policy rejects assignments to envelopes without allocations"
    True
    (any isMissingAllocation reasons)
  assertEqual
    "policy rejects negative entitlements"
    True
    (any isNegativeAllocation reasons)
  assertEqual
    "policy rejects unknown row shapes"
    True
    (any isInvalidRow reasons)
  assertEqual
    "the expected duplicate envelope remains identifiable"
    True
    (any (matchesDuplicate everyday) reasons)

characterizeEnvelopeBudget :: IO ()
characterizeEnvelopeBudget = do
  let journal = mustRight (parseJournal journalInput)
      policy = mustRight (parseEnvelopePolicy policyInput)
      start = fromGregorian 2026 7 1
      end = fromGregorian 2026 7 31
      dateRange = mustRight (mkDateRange start end)
      report = mustRight (envelopeBudget dateRange policy journal)
      jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      everydayConsumption = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 250)
        , mkAmount usd (quantityFromInteger 2)
        ]
      everydayRemaining = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 750)
        , mkAmount usd (quantityFromInteger 8)
        ]
      travelConsumption = balanceFromAmounts
        [mkAmount usd (quantityFromInteger 20)]
      travelRemaining = balanceFromAmounts
        [mkAmount usd (quantityFromInteger 30)]

  assertEqual
    "envelope report retains the explicit range"
    dateRange
    (envelopeBudgetRange report)

  case envelopeBudgetLines report of
    everyday : travel : [] -> do
      assertEqual
        "multi-commodity entitlement remains one envelope balance"
        "Everyday"
        (envelopeNameText (envelopeBudgetEnvelope everyday))
      assertEqual
        "negative expense postings reduce consumption without income-name rules"
        everydayConsumption
        (envelopeBudgetConsumption everyday)
      assertEqual
        "remaining is derived independently per commodity"
        everydayRemaining
        (envelopeBudgetRemaining everyday)
      assertEqual
        "second envelope remains independently allocated"
        "Travel"
        (envelopeNameText (envelopeBudgetEnvelope travel))
      assertEqual
        "travel consumption is range-clipped"
        travelConsumption
        (envelopeBudgetConsumption travel)
      assertEqual
        "travel remaining is derived"
        travelRemaining
        (envelopeBudgetRemaining travel)
    _ -> failTest "expected exactly two allocated envelopes"

  case envelopeBudgetUnassignedExpenses report of
    cancelled : medical : [] -> do
      assertEqual
        "zero-net unassigned activity remains visible"
        "living:cancelled"
        (accountName (envelopeAccount cancelled))
      assertEqual
        "zero-net activity retains canonical zero"
        emptyBalance
        (envelopeAccountBalance cancelled)
      assertEqual
        "unassigned expense accounts remain visible"
        "living:medical"
        (accountName (envelopeAccount medical))
      assertEqual
        "unassigned expense amount remains exact"
        (balanceFromAmounts [mkAmount jpy (quantityFromInteger 30)])
        (envelopeAccountBalance medical)
    _ -> failTest "expected two unassigned expense accounts"

  assertEqual
    "validated journal has no unclassified envelope evidence"
    []
    (envelopeBudgetUnclassifiedAccounts report)

  let rendered = renderEnvelopeBudget report
  assertEqual
    "renderer publishes envelope facts in the terminal style"
    True
    ( all (`T.isInfixOf` rendered)
        [ "\ESC[1;36m== Envelope & Backing ==\ESC[0m"
        , "\ESC[2mHorizon: 2026-07-01..2026-07-31\ESC[0m"
        , "\ESC[2mObserved through: 2026-07-31\ESC[0m"
        , "Envelope"
        , "Entitlement"
        , "Consumption"
        , "Remaining"
        , "Everyday"
        , "1,000 JPY, 10 USD"
        , "250 JPY, 2 USD"
        , "\ESC[32m750 JPY, 8 USD\ESC[0m"
        , "\ESC[33mUnassigned expense accounts\ESC[0m"
        , "living:cancelled"
        , "\ESC[2m0\ESC[0m"
        , "living:medical"
        ]
    )

characterizePolicyValidation :: IO ()
characterizePolicyValidation = do
  let journal = mustRight (parseJournal journalInput)
      dateRange = mustRight
        (mkDateRange (fromGregorian 2026 7 1) (fromGregorian 2026 7 31))
      assetPolicy = mustRight (parseEnvelopePolicy (T.unlines
        [ "allocation\tEveryday\t1000\tJPY"
        , "assignment\twallet:cash\tEveryday"
        ]))
      undeclaredPolicy = mustRight (parseEnvelopePolicy (T.unlines
        [ "allocation\tEveryday\t1000\tJPY"
        , "assignment\tmissing:expense\tEveryday"
        ]))

  case envelopeBudget dateRange assetPolicy journal of
    Left (EnvelopeBudgetError lineNumber
      (EnvelopeAssignedAccountNotExpense account Asset) :| []) -> do
        assertEqual
          "non-expense assignment retains the policy line"
          2
          lineNumber
        assertEqual
          "non-expense assignment names the offending account"
          "wallet:cash"
          (accountName account)
    other -> failTest ("expected non-expense assignment error, got " ++ show other)

  case envelopeBudget dateRange undeclaredPolicy journal of
    Left (EnvelopeBudgetError lineNumber
      (EnvelopeAssignedAccountUndeclared account) :| []) -> do
        assertEqual
          "undeclared assignment retains the policy line"
          2
          lineNumber
        assertEqual
          "undeclared assignment names the missing account"
          "missing:expense"
          (accountName account)
    other -> failTest ("expected undeclared assignment error, got " ++ show other)

characterizeUnclassifiedEvidence :: IO ()
characterizeUnclassifiedEvidence = do
  let jpy = mustRight (mkCommodity "JPY")
      unknownLeft = mustRight (mkAccount "unknown:left")
      unknownRight = mustRight (mkAccount "unknown:right")
      transaction = mustRight (mkTransaction
        (fromGregorian 2026 7 10)
        "Programmatic unknown accounts"
        ( mkPosting unknownLeft (mkAmount jpy (quantityFromInteger 1))
        :| [mkPosting unknownRight (mkAmount jpy (quantityFromInteger (-1)))]
        ))
      journal = journalFromTransactions [transaction]
      policy = mustRight (parseEnvelopePolicy
        "allocation\tEveryday\t1000\tJPY")
      dateRange = mustRight
        (mkDateRange (fromGregorian 2026 7 1) (fromGregorian 2026 7 31))
      report = mustRight (envelopeBudget dateRange policy journal)

  assertEqual
    "programmatic accounts without metadata remain visible"
    2
    (length (envelopeBudgetUnclassifiedAccounts report))
  case envelopeBudgetLines report of
    line : [] ->
      assertEqual
        "unclassified evidence is not invented as envelope consumption"
        emptyBalance
        (envelopeBudgetConsumption line)
    _ -> failTest "expected exactly one envelope allocation"

invalidPolicyInput :: T.Text
invalidPolicyInput = T.unlines
  [ "allocation\tEveryday\t1000\tJPY"
  , "allocation\tEveryday\t2000\tJPY"
  , "assignment\tliving:food\tMissing"
  , "assignment\tliving:food\tEveryday"
  , "allocation\tBroken\t-1\tJPY"
  , "not-a-policy-row"
  ]

policyInput :: T.Text
policyInput = T.unlines
  [ "# kind, identity, exact amount"
  , "allocation\tEveryday\t1000\tJPY"
  , "allocation\tEveryday\t10\tUSD"
  , "allocation\tTravel\t50\tUSD"
  , "assignment\tliving:food\tEveryday"
  , "assignment\tliving:coffee\tEveryday"
  , "assignment\tliving:travel\tTravel"
  ]

journalInput :: T.Text
journalInput = T.unlines
  [ "account wallet:cash"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account wallet:savings"
  , "    type: asset"
  , "    commodity: JPY"
  , ""
  , "account wallet:dollars"
  , "    type: asset"
  , "    commodity: USD"
  , ""
  , "account capital:opening"
  , "    type: equity"
  , "    commodity: JPY"
  , ""
  , "account living:food"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:coffee"
  , "    type: expense"
  , "    commodity: USD"
  , ""
  , "account living:travel"
  , "    type: expense"
  , "    commodity: USD"
  , ""
  , "account living:medical"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "account living:cancelled"
  , "    type: expense"
  , "    commodity: JPY"
  , ""
  , "2026-07-01 Opening balance"
  , "    wallet:cash       2000 JPY"
  , "    capital:opening  -2000 JPY"
  , ""
  , "2026-07-10 Food"
  , "    living:food       300 JPY"
  , "    wallet:cash      -300 JPY"
  , ""
  , "2026-07-12 Coffee"
  , "    living:coffee       2 USD"
  , "    wallet:dollars     -2 USD"
  , ""
  , "2026-07-15 Food refund"
  , "    living:food       -50 JPY"
  , "    wallet:cash        50 JPY"
  , ""
  , "2026-07-20 Travel"
  , "    living:travel      20 USD"
  , "    wallet:dollars    -20 USD"
  , ""
  , "2026-07-22 Medical"
  , "    living:medical     30 JPY"
  , "    wallet:cash       -30 JPY"
  , ""
  , "2026-07-23 Cancelled expense"
  , "    living:cancelled   10 JPY"
  , "    wallet:cash       -10 JPY"
  , ""
  , "2026-07-24 Cancel expense"
  , "    living:cancelled  -10 JPY"
  , "    wallet:cash        10 JPY"
  , ""
  , "2026-07-25 Transfer"
  , "    wallet:savings    100 JPY"
  , "    wallet:cash      -100 JPY"
  , ""
  , "2026-08-01 Food after range"
  , "    living:food       500 JPY"
  , "    wallet:cash      -500 JPY"
  ]

isDuplicateAllocation :: EnvelopePolicyErrorReason -> Bool
isDuplicateAllocation reason = case reason of
  DuplicateEnvelopeAllocation _ _ -> True
  _                               -> False

isDuplicateAssignment :: EnvelopePolicyErrorReason -> Bool
isDuplicateAssignment reason = case reason of
  DuplicateEnvelopeAssignment _ -> True
  _                             -> False

isMissingAllocation :: EnvelopePolicyErrorReason -> Bool
isMissingAllocation reason = case reason of
  AssignmentToUnallocatedEnvelope _ -> True
  _                                 -> False

isNegativeAllocation :: EnvelopePolicyErrorReason -> Bool
isNegativeAllocation reason = case reason of
  NegativeEnvelopeAllocation _ _ -> True
  _                              -> False

isInvalidRow :: EnvelopePolicyErrorReason -> Bool
isInvalidRow reason = case reason of
  InvalidEnvelopePolicyRow _ -> True
  _                          -> False

matchesDuplicate :: EnvelopeName -> EnvelopePolicyErrorReason -> Bool
matchesDuplicate expected reason = case reason of
  DuplicateEnvelopeAllocation actual _ -> actual == expected
  _                                    -> False

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure

failTest :: String -> IO value
failTest message = do
  putStrLn ("  [FAIL] " ++ message)
  exitFailure
