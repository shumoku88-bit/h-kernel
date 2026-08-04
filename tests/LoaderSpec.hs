{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Exception (bracket)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import HKernel.Account
  ( AccountRegistry
  , AccountType(..)
  , accountTypeFor
  , mkAccount
  )
import HKernel.Journal
  ( journalAccountRegistry
  , journalTransactions
  )
import HKernel.Loader
import HKernel.Render (renderLoadError)
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , getTemporaryDirectory
  , removeFile
  , removePathForcibly
  )
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

main :: IO ()
main = withTemporaryDirectory $ \directory -> do
  relativeIncludeTest directory
  syntheticMasterFileIntegrationTest directory
  rootReadFailurePathTest directory
  missingIncludeReadPathTest directory
  directDuplicateIncludeTest directory
  diamondDuplicateIncludeTest directory
  includeCycleTest directory

relativeIncludeTest :: FilePath -> IO ()
relativeIncludeTest directory = do
  let root = directory </> "root.journal"
      parts = directory </> "parts"
      accounts = parts </> "accounts.journal"
      transactions = parts </> "transactions.journal"

  createDirectoryIfMissing True parts
  TIO.writeFile root "include parts/accounts.journal\n"
  TIO.writeFile accounts (T.unlines
    [ "account assets:cash"
    , "    type: asset"
    , "    commodity: JPY"
    , ""
    , "account equity:opening"
    , "    type: equity"
    , "    commodity: JPY"
    , ""
    , "include transactions.journal"
    ])
  TIO.writeFile transactions (T.unlines
    [ "2026-08-01 Opening balance"
    , "    assets:cash  1000 JPY"
    , "    equity:opening"
    ])

  result <- loadJournal root
  case result of
    Right journal -> assertEqual
      "nested includes resolve relative to the including document"
      1
      (length (journalTransactions journal))
    Left err -> failTest
      ("relative include loading failed: " ++ T.unpack (renderLoadError err))

-- | Exercise a synthetic master-file entry shape: callers provide only
-- @journal-tree/master.journal@ while that master file owns separate Account
-- and Transaction include trees. Transactions intentionally appear before the
-- Account declarations to confirm validation happens after full expansion.
syntheticMasterFileIntegrationTest :: FilePath -> IO ()
syntheticMasterFileIntegrationTest directory = do
  let journalTree = directory </> "journal-tree"
      master = journalTree </> "master.journal"
      accountsDirectory = journalTree </> "accounts"
      accountsIndex = accountsDirectory </> "accounts.journal"
      chart = accountsDirectory </> "chart.journal"
      transactionsDirectory = journalTree </> "transactions"
      transactionsIndex = transactionsDirectory </> "transactions.journal"
      opening = transactionsDirectory </> "opening.journal"
      august = transactionsDirectory </> "2026-08.journal"

  createDirectoryIfMissing True accountsDirectory
  createDirectoryIfMissing True transactionsDirectory
  TIO.writeFile master (T.unlines
    [ "include transactions/transactions.journal"
    , "include accounts/accounts.journal"
    ])
  TIO.writeFile accountsIndex "include chart.journal\n"
  TIO.writeFile chart (T.unlines
    [ "account wallet:bank"
    , "    type: asset"
    , "    commodity: JPY"
    , ""
    , "account equity:opening"
    , "    type: equity"
    , "    commodity: JPY"
    , ""
    , "account income:salary"
    , "    type: income"
    , "    commodity: JPY"
    , ""
    , "account living:food"
    , "    type: expense"
    , "    commodity: JPY"
    ])
  TIO.writeFile transactionsIndex (T.unlines
    [ "include opening.journal"
    , "include 2026-08.journal"
    ])
  TIO.writeFile opening (T.unlines
    [ "2026-07-31 Opening balance"
    , "    wallet:bank  100000 JPY"
    , "    equity:opening"
    ])
  TIO.writeFile august (T.unlines
    [ "2026-08-01 Salary"
    , "    wallet:bank  200000 JPY"
    , "    income:salary"
    , ""
    , "2026-08-02 Groceries"
    , "    living:food  1200 JPY"
    , "    wallet:bank"
    ])

  result <- loadJournal master
  case result of
    Right journal -> do
      assertEqual
        "hledger master file loads every included transaction"
        3
        (length (journalTransactions journal))
      let registry = journalAccountRegistry journal
      assertAccountType
        "master include tree retains Asset metadata"
        registry
        "wallet:bank"
        Asset
      assertAccountType
        "master include tree retains Income metadata"
        registry
        "income:salary"
        Income
      assertAccountType
        "master include tree retains Expense metadata"
        registry
        "living:food"
        Expense
    Left err -> failTest
      ("hledger master loading failed: " ++ T.unpack (renderLoadError err))

rootReadFailurePathTest :: FilePath -> IO ()
rootReadFailurePathTest directory = do
  let missing = directory </> "missing-root.journal"

  result <- loadJournal missing
  case result of
    Left (JournalReadFailed failure) -> do
      assertEqual
        "root read failure has a one-file non-empty path"
        [missing]
        (NonEmpty.toList (journalReadPath failure))
      assertEqual
        "root read failure renders the failed file"
        True
        ("missing-root.journal" `T.isInfixOf` renderLoadError (JournalReadFailed failure))
    Left err -> failTest
      ("wrong root loader failure: " ++ T.unpack (renderLoadError err))
    Right _ -> failTest "missing root journal was accepted"

missingIncludeReadPathTest :: FilePath -> IO ()
missingIncludeReadPathTest directory = do
  let root = directory </> "read-path-root.journal"
      parts = directory </> "read-path-parts"
      accounts = parts </> "accounts.journal"
      missing = parts </> "missing.journal"

  createDirectoryIfMissing True parts
  TIO.writeFile root "include read-path-parts/accounts.journal\n"
  TIO.writeFile accounts "include missing.journal\n"

  result <- loadJournal root
  case result of
    Left (JournalReadFailed failure) -> do
      assertEqual
        "read failure identifies the file that could not be opened"
        missing
        (NonEmpty.last (journalReadPath failure))
      assertEqual
        "read failure retains the complete root-to-file include path"
        [root, accounts, missing]
        (NonEmpty.toList (journalReadPath failure))
      let rendered = renderLoadError (JournalReadFailed failure)
      assertEqual
        "read failure rendering includes the root traversal"
        True
        ("read-path-root.journal ->" `T.isInfixOf` rendered)
      assertEqual
        "read failure rendering includes the intermediate include"
        True
        ("accounts.journal ->" `T.isInfixOf` rendered)
    Left err -> failTest
      ("wrong loader failure: " ++ T.unpack (renderLoadError err))
    Right _ -> failTest "missing nested include was accepted"

directDuplicateIncludeTest :: FilePath -> IO ()
directDuplicateIncludeTest directory = do
  let root = directory </> "duplicate-root.journal"
      shared = directory </> "duplicate-shared.journal"

  TIO.writeFile root (T.unlines
    [ "include duplicate-shared.journal"
    , "include duplicate-shared.journal"
    ])
  TIO.writeFile shared ""

  result <- loadJournal root
  case result of
    Left (IncludeAlreadyLoaded firstTrace repeatedTrace) -> do
      assertEqual
        "direct duplicate retains the first include trace"
        [root, shared]
        (NonEmpty.toList (includeTracePath firstTrace))
      assertEqual
        "direct duplicate retains the repeated include trace"
        [root, shared]
        (NonEmpty.toList (includeTracePath repeatedTrace))
      assertEqual
        "direct duplicate renders an explicit error"
        True
        ("included more than once" `T.isInfixOf`
          renderLoadError (IncludeAlreadyLoaded firstTrace repeatedTrace))
    Left err -> failTest
      ("wrong direct duplicate failure: " ++ T.unpack (renderLoadError err))
    Right _ -> failTest "direct duplicate include was accepted"

diamondDuplicateIncludeTest :: FilePath -> IO ()
diamondDuplicateIncludeTest directory = do
  let root = directory </> "diamond-root.journal"
      left = directory </> "diamond-left.journal"
      right = directory </> "diamond-right.journal"
      shared = directory </> "diamond-shared.journal"

  TIO.writeFile root (T.unlines
    [ "include diamond-left.journal"
    , "include diamond-right.journal"
    ])
  TIO.writeFile left "include diamond-shared.journal\n"
  TIO.writeFile right "include diamond-shared.journal\n"
  TIO.writeFile shared ""

  result <- loadJournal root
  case result of
    Left (IncludeAlreadyLoaded firstTrace repeatedTrace) -> do
      assertEqual
        "diamond duplicate retains the first root-to-file trace"
        [root, left, shared]
        (NonEmpty.toList (includeTracePath firstTrace))
      assertEqual
        "diamond duplicate retains the repeated root-to-file trace"
        [root, right, shared]
        (NonEmpty.toList (includeTracePath repeatedTrace))
      let rendered = renderLoadError
            (IncludeAlreadyLoaded firstTrace repeatedTrace)
      assertEqual
        "diamond duplicate rendering identifies the first branch"
        True
        ("diamond-left.journal ->" `T.isInfixOf` rendered)
      assertEqual
        "diamond duplicate rendering identifies the repeated branch"
        True
        ("diamond-right.journal ->" `T.isInfixOf` rendered)
    Left err -> failTest
      ("wrong diamond duplicate failure: " ++ T.unpack (renderLoadError err))
    Right _ -> failTest "diamond duplicate include was accepted"

includeCycleTest :: FilePath -> IO ()
includeCycleTest directory = do
  let first = directory </> "cycle-a.journal"
      second = directory </> "cycle-b.journal"

  TIO.writeFile first "include cycle-b.journal\n"
  TIO.writeFile second "include cycle-a.journal\n"

  result <- loadJournal first
  case result of
    Left (IncludeCycle paths) -> do
      assertEqual
        "include cycles retain the closed path"
        [first, second, first]
        (NonEmpty.toList paths)
      assertEqual
        "include cycles render the traversal"
        True
        ("cycle-a.journal ->" `T.isInfixOf` renderLoadError (IncludeCycle paths))
    Left err -> failTest
      ("wrong loader failure: " ++ T.unpack (renderLoadError err))
    Right _ -> failTest "include cycle was accepted"

assertAccountType
  :: String
  -> AccountRegistry
  -> T.Text
  -> AccountType
  -> IO ()
assertAccountType label registry name expected =
  case mkAccount name of
    Left err -> failTest
      ("invalid Account fixture " ++ T.unpack name ++ ": " ++ show err)
    Right account -> assertEqual
      label
      (Just expected)
      (accountTypeFor account registry)

withTemporaryDirectory :: (FilePath -> IO value) -> IO value
withTemporaryDirectory = bracket create removePathForcibly
  where
    create = do
      parent <- getTemporaryDirectory
      (path, handle) <- openTempFile parent "h-kernel-loader-test"
      hClose handle
      removeFile path
      createDirectory path
      pure path

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
