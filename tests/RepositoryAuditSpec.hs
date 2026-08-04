{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import RepositoryAudit
import System.Exit (exitFailure)

main :: IO ()
main = do
  characterizeCleanInventory
  characterizeOwnershipFindings
  characterizeDocumentIndexAdmission

characterizeCleanInventory :: IO ()
characterizeCleanInventory = do
  let source = mustPath "src/HKernel/Owned.hs"
      document = mustPath "docs/ARCHITECTURE.md"
      index = mustIndex
        [documentEntry document Architecture]
      inventory = repositoryInventory
        [source, document]
        [source]
        index

  assertEqual
    "a Cabal-owned source and indexed document produce no findings"
    []
    (auditRepository inventory)

characterizeOwnershipFindings :: IO ()
characterizeOwnershipFindings = do
  let ownedSource = mustPath "src/HKernel/Owned.hs"
      orphanSource = mustPath "tools/Orphan.hs"
      unindexedDocument = mustPath "docs/UNINDEXED.md"
      missingDocument = mustPath "docs/MISSING.md"
      index = mustIndex
        [documentEntry missingDocument Reference]
      inventory = repositoryInventory
        [ownedSource, orphanSource, unindexedDocument]
        [ownedSource]
        index
      expected =
        [ UnregisteredHaskellFile orphanSource
        , UnindexedDocument unindexedDocument
        , MissingIndexedDocument missingDocument
        ]

  assertEqual
    "findings preserve Cabal, document coverage, and stale-index order"
    expected
    (auditRepository inventory)

characterizeDocumentIndexAdmission :: IO ()
characterizeDocumentIndexAdmission = do
  let manifest =
        "[[documents]]\n"
          <> "path = \"docs/HASKELL_NATIVE_CODE_POLICY.md\"\n"
          <> "role = \"policy\"\n"
      path = mustPath "docs/HASKELL_NATIVE_CODE_POLICY.md"

  case parseDocumentIndex manifest of
    Left errors -> failTest
      "valid document index"
      ("unexpected errors: " ++ show errors)
    Right index -> assertEqual
      "document index retains the declared role"
      (Just Policy)
      (lookupDocumentRole path index)

  assertLeft
    "unknown document roles are rejected"
    (parseDocumentIndex
      ("[[documents]]\n"
        <> "path = \"docs/UNKNOWN.md\"\n"
        <> "role = \"misc\"\n"))

  let duplicate = documentEntry path Policy
  case mkDocumentIndex [duplicate, duplicate] of
    Left errors -> assertEqual
      "duplicate document paths remain a typed index conflict"
      [DuplicateIndexedDocument path]
      (NonEmpty.toList errors)
    Right value -> failTest
      "duplicate document index"
      ("unexpectedly accepted: " ++ show value)

mustPath :: String -> RepositoryPath
mustPath value = case mkRepositoryPath (T.pack value) of
  Right path -> path
  Left err -> error ("invalid path fixture: " ++ show err)

mustIndex :: [DocumentEntry] -> DocumentIndex
mustIndex entries = case mkDocumentIndex entries of
  Right index -> index
  Left errors -> error ("invalid index fixture: " ++ show errors)

assertLeft :: Show value => String -> Either error value -> IO ()
assertLeft label result = case result of
  Left _ -> pass label
  Right value -> failTest label ("unexpectedly accepted: " ++ show value)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = pass label
  | otherwise = failTest label
      ("expected " ++ show expected ++ ", but got " ++ show actual)

pass :: String -> IO ()
pass label = putStrLn ("  [PASS] " ++ label)

failTest :: String -> String -> IO ()
failTest label detail = do
  putStrLn ("  [FAIL] " ++ label)
  putStrLn ("    " ++ detail)
  exitFailure
