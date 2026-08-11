{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Test.Support (mustRight, mustJust, assertEqual)
import Control.Monad (unless)
import Data.List.NonEmpty (NonEmpty((:|)))
import qualified Data.List.NonEmpty as NonEmpty
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import HKernel.Account
import HKernel.Engine
import HKernel.Journal
import HKernel.Ledger
import HKernel.Money
import HKernel.Render
import HKernel.Report
import HKernel.Report.Presentation
import System.Exit (exitFailure)
import Test.QuickCheck (isSuccess, quickCheckResult)

main :: IO ()
main = do
  putStrLn "== h-kernel money tests =="
  unitTests
  results <- sequence
    [ quickCheckResult propBalanceCommutative
    , quickCheckResult propBalanceInverse
    , quickCheckResult propValidatedJournalBalances
    ]
  unless (all isSuccess results) exitFailure

unitTests :: IO ()
unitTests = do
  assertEqual "empty commodity is rejected"
    (Left EmptyCommodity)
    (mkCommodity "")
  assertEqual "commodity whitespace is rejected"
    (Left (CommodityContainsWhitespace "US D"))
    (mkCommodity "US D")

  let jpy = mustRight (mkCommodity "JPY")
      usd = mustRight (mkCommodity "USD")
      oneTenth = mustRight (parseQuantity "0.1")
      twoTenths = mustRight (parseQuantity "0.2")
      threeTenths = mustRight (parseQuantity "0.3")

  assertEqual "decimal addition is exact"
    threeTenths
    (addQuantity oneTenth twoTenths)
  assertEqual "integral quantities render without a fake decimal part"
    "15000"
    (renderQuantity (quantityFromInteger 15000))

  let mixed = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 15000)
        , mkAmount usd (quantityFromInteger 100)
        ]
  assertEqual "different commodities remain separate" 2 (length (balanceEntries mixed))
  assertEqual "JPY can be looked up independently"
    (quantityFromInteger 15000)
    (lookupBalance jpy mixed)
  assertEqual "USD can be looked up independently"
    (quantityFromInteger 100)
    (lookupBalance usd mixed)

  let cancelled = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 10)
        , mkAmount jpy (quantityFromInteger (-10))
        ]
  assertEqual "zero entries are removed" emptyBalance cancelled
  assertEqual "zero balance has no entries" [] (balanceEntries cancelled)

  accountMetadataTests jpy
  includeTests
  transactionTests jpy usd
  journalTests jpy usd
  engineTests jpy usd

accountMetadataTests :: Commodity -> IO ()
accountMetadataTests jpy = do
  let input = T.unlines
        [ "account wallet:cash"
        , "    commodity: JPY"
        , "    type: asset"
        , ""
        , "account funding:owner"
        , "    type: equity"
        , ""
        , "2026-08-01 Opening balance"
        , "    wallet:cash  1000 JPY"
        , "    funding:owner"
        ]
      journal = mustRight (parseJournal input)
      registry = journalAccountRegistry journal
      wallet = mustRight (mkAccount "wallet:cash")
      funding = mustRight (mkAccount "funding:owner")
      walletDeclaration = mustJust (lookupAccountDeclaration wallet registry)
      fundingDeclaration = mustJust (lookupAccountDeclaration funding registry)
      conventionalButUndeclared = mustRight (mkAccount "assets:looks-valid")

  assertEqual "account directives populate the registry"
    2
    (length (accountDeclarations registry))
  assertEqual "declared account type is available by identity"
    (Just Asset)
    (accountTypeFor wallet registry)
  assertEqual "account default commodity is retained as typed metadata"
    (Just jpy)
    (declaredAccountDefaultCommodity walletDeclaration)
  assertEqual "account commodity metadata can appear before type metadata"
    Asset
    (declaredAccountType walletDeclaration)
  assertEqual "an account may deliberately have no default commodity"
    Nothing
    (declaredAccountDefaultCommodity fundingDeclaration)
  assertEqual "reports use metadata rather than account-name prefixes"
    (Just Asset)
    (classifyAccount journal wallet)
  assertEqual "a conventional prefix does not replace a declaration"
    Nothing
    (classifyAccount journal conventionalButUndeclared)

  let missingType = "account assets:cash\n"
      cash = mustRight (mkAccount "assets:cash")
  assertEqual "an account directive requires a type"
    (Left (JournalError 1 (AccountDirectiveHasNoType cash) :| []))
    (parseJournal missingType)

  let invalidType = T.unlines
        [ "account assets:cash"
        , "    type: current-asset"
        ]
  assertEqual "unknown account types are rejected at their source line"
    (Left (JournalError 2 (InvalidAccountType "current-asset") :| []))
    (parseJournal invalidType)

  let invalidCommodity = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , "    commodity:"
        ]
  assertEqual "invalid account commodities are rejected at their source line"
    (Left (JournalError 3 (InvalidAccountCommodity EmptyCommodity) :| []))
    (parseJournal invalidCommodity)

  let duplicateType = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , "    type: expense"
        ]
  assertEqual "duplicate type metadata is rejected instead of using last-write-wins"
    (Left (JournalError 3 (DuplicateAccountType cash) :| []))
    (parseJournal duplicateType)

  let duplicateCommodity = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , "    commodity: JPY"
        , "    commodity: USD"
        ]
  assertEqual "duplicate default commodities are rejected instead of using last-write-wins"
    (Left (JournalError 4 (DuplicateAccountCommodity cash) :| []))
    (parseJournal duplicateCommodity)

  let duplicateAccount = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , ""
        , "account assets:cash"
        , "    type: expense"
        ]
  assertEqual "duplicate account declarations are rejected"
    (Left (JournalError 4 (DuplicateAccountDirective cash) :| []))
    (parseJournal duplicateAccount)

  let undeclared = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , ""
        , "2026-08-01 Buy food"
        , "    expenses:food  1000 JPY"
        , "    assets:cash"
        ]
      food = mustRight (mkAccount "expenses:food")
      undeclaredError = JournalError 5 (UndeclaredPostingAccount food)
  assertEqual "posting accounts must be declared"
    (Left (undeclaredError :| []))
    (parseJournal undeclared)
  assertEqual "undeclared account errors name the posting account"
    True
    ("posting uses undeclared account: expenses:food"
      `T.isInfixOf` renderJournalErrors (undeclaredError :| []))

  let usd = mustRight (mkCommodity "USD")
      mismatchedCommodity = T.unlines
        [ "account expenses:food"
        , "    type: expense"
        , "    commodity: JPY"
        , ""
        , "account assets:cash"
        , "    type: asset"
        , ""
        , "2026-08-01 Buy food"
        , "    expenses:food  100 USD"
        , "    assets:cash"
        ]
      mismatchError = JournalError 9
        (PostingCommodityMismatch food jpy usd)
  assertEqual "posting commodities must match account defaults"
    (Left (mismatchError :| []))
    (parseJournal mismatchedCommodity)
  assertEqual "commodity mismatch errors show expected and actual values"
    True
    ("posting commodity USD conflicts with default JPY for account expenses:food"
      `T.isInfixOf` renderJournalErrors (mismatchError :| []))

  let forwardDeclared = T.unlines
        [ "2026-08-01 Opening balance"
        , "    wallet:cash  1000 JPY"
        , "    funding:owner"
        , ""
        , "account wallet:cash"
        , "    type: asset"
        , ""
        , "account funding:owner"
        , "    type: equity"
        ]
  _ <- assertRight
    "account declarations may appear after transactions"
    (parseJournal forwardDeclared)
  pure ()

includeTests :: IO ()
includeTests = do
  assertEqual "empty include paths are rejected"
    (Left EmptyIncludePath)
    (mkInclude "   ")

  let accountsInclude = mustRight (mkInclude "accounts.journal")
      input = T.unlines
        [ "include accounts.journal ; account declarations"
        , ""
        , "2026-08-01 Opening balance"
        , "    assets:cash  1000 JPY"
        , "    equity:opening"
        ]
      document = mustRight (parseJournalDocument input)
      unresolved = JournalError 1 (UnresolvedInclude accountsInclude)

  assertEqual "include directives are retained as typed syntax"
    [accountsInclude]
    (journalDocumentIncludes document)
  assertEqual "syntax parsing may defer declarations to included documents"
    (Left (unresolved :| []))
    (validateJournalDocument document)
  assertEqual "standalone parsing never ignores unresolved includes"
    (Left (unresolved :| []))
    (parseJournal input)
  assertEqual "unresolved include errors retain their path"
    True
    ("include has not been resolved: accounts.journal"
      `T.isInfixOf` renderJournalErrors (unresolved :| []))
  assertEqual "empty include directives report their source line"
    (Left (JournalError 1 (InvalidIncludePath EmptyIncludePath) :| []))
    (fmap (const ()) (parseJournalDocument "include   \n"))

engineTests :: Commodity -> Commodity -> IO ()
engineTests jpy usd = do
  let input = T.unlines
        [ "account assets:cash"
        , "    type: asset"
        , ""
        , "account expenses:food"
        , "    type: expense"
        , ""
        , "account assets:wallet"
        , "    type: asset"
        , ""
        , "account equity:fx:usd"
        , "    type: equity"
        , ""
        , "account income:refund"
        , "    type: income"
        , ""
        , "2026-08-01 Buy food"
        , "    expenses:food  1000 JPY"
        , "    assets:cash"
        , ""
        , "2026-08-02 Receive dollars"
        , "    assets:wallet  100 USD"
        , "    equity:fx:usd"
        , ""
        , "2026-09-01 Future refund"
        , "    assets:cash  500 JPY"
        , "    income:refund"
        ]
      journal = mustRight (parseJournal input)
      balances = accountBalances journal
      cash = mustRight (mkAccount "assets:cash")
      food = mustRight (mkAccount "expenses:food")
      assets = mustRight (mkAccount "assets")
      expectedCash = singletonBalance
        (mkAmount jpy (quantityFromInteger (-500)))
      expectedFood = singletonBalance
        (mkAmount jpy (quantityFromInteger 1000))

  assertEqual "validated journal remains globally balanced"
    emptyBalance
    (journalBalance journal)
  assertEqual "account aggregation preserves its commodity"
    expectedCash
    (accountBalance cash balances)
  assertEqual "expense account balance is aggregated exactly"
    expectedFood
    (accountBalance food balances)
  assertEqual "account hierarchy respects segment boundaries"
    2
    (length (accountBalanceEntries (accountsWithin assets balances)))

  let cutoff = fromGregorian 2026 8 31
      cutoffBalances = accountBalancesThrough cutoff journal
      cashAtCutoff = singletonBalance
        (mkAmount jpy (quantityFromInteger (-1000)))
  assertEqual "as-of query excludes future transactions"
    cashAtCutoff
    (accountBalance cash cutoffBalances)

  let start = fromGregorian 2026 9 1
      end = fromGregorian 2026 9 1
      dateRange = mustRight (mkDateRange start end)
  assertEqual "date-range aggregation includes both endpoints"
    (singletonBalance (mkAmount jpy (quantityFromInteger 500)))
    (accountBalance cash (accountBalancesInRange dateRange journal))
  assertEqual "invalid date ranges cannot be constructed"
    (Left (RangeStartsAfterEnd start cutoff))
    (mkDateRange start cutoff)

  let wallet = mustRight (mkAccount "assets:wallet")
  assertEqual "another currency is retained independently"
    (singletonBalance (mkAmount usd (quantityFromInteger 100)))
    (accountBalance wallet balances)

  let trial = trialBalanceAsOf cutoff journal
  assertEqual "trial balance totals all commodities independently"
    emptyBalance
    (trialBalanceTotal trial)

  let august = mustRight
        (mkDateRange (fromGregorian 2026 8 1) (fromGregorian 2026 8 31))
      pnl = profitAndLoss august journal
      expenseTotal = singletonBalance
        (mkAmount jpy (quantityFromInteger 1000))
  assertEqual "P&L reports period expenses"
    expenseTotal
    (totalExpenses pnl)
  assertEqual "P&L derives loss without mixing currencies"
    (negateBalance expenseTotal)
    (netIncome pnl)
  assertEqual "declared non-P&L counterpart accounts are not classification errors"
    []
    (profitAndLossUnclassified pnl)

  let sheet = balanceSheetAsOf cutoff journal
      expectedAssets = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger (-1000))
        , mkAmount usd (quantityFromInteger 100)
        ]
  assertEqual "balance sheet retains its multi-currency asset total"
    expectedAssets
    (totalAssets sheet)
  assertEqual "unclosed income and expenses become current earnings"
    (negateBalance expenseTotal)
    (currentEarnings sheet)
  assertEqual "classified balance sheet satisfies its equation"
    emptyBalance
    (accountingEquationDelta sheet)

  let renderedSheet = renderBalanceSheet sheet
  assertEqual "renderer uses accounting parentheses without mixing commodities"
    True
    ("(1,000 JPY)" `T.isInfixOf` renderedSheet
      && "100 USD" `T.isInfixOf` renderedSheet)
  let minusSheet = renderBalanceSheetWithPresentation
        (defaultPresentationConfig
          { presentationNegativeStyle = LeadingMinus })
        sheet
  assertEqual "renderer selects leading minus without changing commodities"
    True
    ("-1,000 JPY" `T.isInfixOf` minusSheet
      && "100 USD" `T.isInfixOf` minusSheet)
  assertEqual "renderer reports a verified equation in the terminal success style"
    True
    ("Balanced: \ESC[32mYES\ESC[0m" `T.isInfixOf` renderedSheet)

  let unknownAccount = mustRight (mkAccount "assets-old:test")
      unknownCounterpart = mustRight (mkAccount "equity:test")
      unknownTransaction = mustRight (mkTransaction
        (fromGregorian 2026 9 2)
        "Programmatic unknown accounts"
        ( mkPosting unknownAccount
            (mkAmount jpy (quantityFromInteger 1))
        :| [ mkPosting unknownCounterpart
              (mkAmount jpy (quantityFromInteger (-1)))
           ]
        ))
      sheetWithUnknown = balanceSheetAsOf
        (fromGregorian 2026 9 2)
        (journalFromTransactions [unknownTransaction])
  assertEqual "programmatic undeclared accounts remain visible to reports"
    2
    (length (balanceSheetUnclassified sheetWithUnknown))
  assertEqual "unclassified postings are not folded into the accounting equation"
    emptyBalance
    (accountingEquationDelta sheetWithUnknown)
  assertEqual "unclassified accounts prevent a false balanced status"
    True
    ("Balanced: \ESC[31mNO\ESC[0m"
      `T.isInfixOf` renderBalanceSheet sheetWithUnknown)

journalTests :: Commodity -> Commodity -> IO ()
journalTests jpy usd = do
  let validJournal = T.unlines
        [ "account expenses:food"
        , "    type: expense"
        , ""
        , "account assets:cash"
        , "    type: asset"
        , ""
        , "2026-08-01 Buy food"
        , "    expenses:food  1000 JPY"
        , "    assets:cash"
        ]
  journal <- assertRight "journal infers one omitted amount" (parseJournal validJournal)
  assertEqual "journal contains one validated transaction"
    1
    (length (journalTransactions journal))
  assertEqual "parsed transactions are balanced"
    [emptyBalance]
    (map transactionBalance (journalTransactions journal))

  let malformed = T.unlines
        [ "2026-08-01 Bad amount"
        , "    expenses:food  twelve JPY"
        , "    assets:cash"
        , ""
        , "2026-08-02 Another bad amount"
        , "    expenses:food  nope USD"
        , "    assets:cash"
        ]
  case parseJournal malformed of
    Left errors -> assertEqual "parser accumulates errors with line numbers"
      [2, 6]
      (map journalErrorLine (NonEmpty.toList errors))
    Right result -> do
      putStrLn ("  [FAIL] malformed journal was accepted: " ++ show result)
      exitFailure

  let unbalancedRemainder = singletonBalance
        (mkAmount jpy (quantityFromInteger 100))
      unbalanced = T.unlines
        [ "2026-08-01 Unbalanced"
        , "    expenses:food  1000 JPY"
        , "    assets:cash  -900 JPY"
        ]
  assertEqual "unbalanced journal transaction is rejected"
    (Left (JournalError 1
      (InvalidTransaction (UnbalancedTransaction unbalancedRemainder)) :| []))
    (parseJournal unbalanced)

  let multipleMissing = T.unlines
        [ "2026-08-01 Ambiguous"
        , "    expenses:food"
        , "    assets:cash"
        ]
  assertEqual "multiple omitted amounts are rejected"
    (Left (JournalError 1 (MultipleElidedAmounts [2, 3]) :| []))
    (parseJournal multipleMissing)

  let multiCurrencyRemainder = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger 15000)
        , mkAmount usd (quantityFromInteger (-100))
        ]
      ambiguousCurrency = T.unlines
        [ "2026-08-01 Ambiguous currency"
        , "    equity:fx:jpy  15000 JPY"
        , "    equity:fx:usd  -100 USD"
        , "    assets:bank"
        ]
  assertEqual "one omitted amount cannot absorb several currencies"
    (Left (JournalError 4
      (CannotInferElidedAmount multiCurrencyRemainder) :| []))
    (parseJournal ambiguousCurrency)

transactionTests :: Commodity -> Commodity -> IO ()
transactionTests jpy usd = do
  assertEqual "account surrounding whitespace is rejected"
    (Left (AccountHasSurroundingWhitespace " assets:cash"))
    (mkAccount " assets:cash")

  let date = fromGregorian 2026 8 1
      cash = mustRight (mkAccount "assets:cash")
      food = mustRight (mkAccount "expenses:food")
      bankJpy = mustRight (mkAccount "assets:bank:jpy")
      bankUsd = mustRight (mkAccount "assets:bank:usd")
      fxJpy = mustRight (mkAccount "equity:fx:jpy")
      fxUsd = mustRight (mkAccount "equity:fx:usd")
      posting account commodity value =
        mkPosting account (mkAmount commodity (quantityFromInteger value))

      balancedResult = mkTransaction date "Buy food"
        (posting food jpy 1000 :| [posting cash jpy (-1000)])

  balanced <- assertRight "balanced transaction is accepted" balancedResult
  assertEqual "validated transaction has zero balance"
    emptyBalance
    (transactionBalance balanced)

  assertEqual "a transaction needs at least two postings"
    (Left (TooFewPostings 1))
    (mkTransaction date "Incomplete" (posting cash jpy 1 :| []))

  let expectedRemainder = singletonBalance (mkAmount jpy (quantityFromInteger 1))
  assertEqual "unbalanced transaction reports its remainder"
    (Left (UnbalancedTransaction expectedRemainder))
    (mkTransaction date "Unbalanced"
      (posting food jpy 1001 :| [posting cash jpy (-1000)]))

  let crossCurrencyRemainder = balanceFromAmounts
        [ mkAmount jpy (quantityFromInteger (-15000))
        , mkAmount usd (quantityFromInteger 100)
        ]
  assertEqual "different currencies cannot cancel each other"
    (Left (UnbalancedTransaction crossCurrencyRemainder))
    (mkTransaction date "Invalid FX"
      (posting bankJpy jpy (-15000) :| [posting bankUsd usd 100]))

  fx <- assertRight "FX transaction balanced per currency is accepted"
    (mkTransaction date "Exchange JPY for USD"
      ( posting bankJpy jpy (-15000)
      :| [ posting fxJpy jpy 15000
         , posting bankUsd usd 100
         , posting fxUsd usd (-100)
         ]
      ))
  assertEqual "multi-currency transaction has zero balance"
    emptyBalance
    (transactionBalance fx)

propValidatedJournalBalances :: Integer -> Bool
propValidatedJournalBalances value =
  isZeroBalance (journalBalance (journalFromTransactions [transaction]))
  where
    commodity = mustRight (mkCommodity "JPY")
    debitAccount = mustRight (mkAccount "assets:cash")
    creditAccount = mustRight (mkAccount "equity:test")
    amount = mkAmount commodity (quantityFromInteger value)
    transaction = mustRight (mkTransaction
      (fromGregorian 2026 1 1)
      "Generated balanced transaction"
      ( mkPosting debitAccount amount
      :| [mkPosting creditAccount (negateAmount amount)]
      ))

propBalanceCommutative :: Integer -> Integer -> Bool
propBalanceCommutative x y =
  addBalance (integerBalance "JPY" x) (integerBalance "USD" y)
    == addBalance (integerBalance "USD" y) (integerBalance "JPY" x)

propBalanceInverse :: Integer -> Bool
propBalanceInverse value =
  isZeroBalance (addBalance balance (negateBalance balance))
  where
    balance = integerBalance "JPY" value

integerBalance :: Text -> Integer -> Balance
integerBalance code value =
  singletonBalance (mkAmount commodity (quantityFromInteger value))
  where
    commodity = mustRight (mkCommodity code)





assertRight :: Show error => String -> Either error value -> IO value
assertRight label result = case result of
  Right value -> do
    putStrLn ("  [PASS] " ++ label)
    pure value
  Left err -> do
    putStrLn ("  [FAIL] " ++ label ++ ": " ++ show err)
    exitFailure

