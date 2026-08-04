{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import HKernel.Account (mkAccount)
import HKernel.Editor.ActualAppend
import HKernel.Editor.ActualReverse
import HKernel.Editor.ActualWriter
import HKernel.Money (mkCommodity, parseQuantity)
import HKernel.Plan.Completion (mkActualTransactionId)

die :: String -> IO a
die msg = hPutStrLn stderr msg >> exitFailure

parsePostings :: [String] -> IO [IntentPosting]
parsePostings [] = pure []
parsePostings (acctStr:qtyStr:commStr:rest) = do
  acct <- either (die . show) pure (mkAccount (T.pack acctStr))
  qty <- either (die . show) pure (parseQuantity (T.pack qtyStr))
  commOpt <- if commStr == "-"
    then pure Nothing
    else either (die . show) (pure . Just) (mkCommodity (T.pack commStr))
  restPostings <- parsePostings rest
  pure (IntentPosting acct qty commOpt : restPostings)
parsePostings _ = die "Invalid number of arguments for postings. Expected triplets of <account> <qty> <comm> (use '-' for default commodity)."

main :: IO ()
main = do
  args <- getArgs
  let commitFlag = "--commit" `elem` args
      cleanArgs = filter (/= "--commit") args

  case cleanArgs of
    ("append":journalFile:dateStr:desc:postingArgs) -> do
      date <- case parseTimeM True defaultTimeLocale "%Y-%m-%d" dateStr of
        Just d -> pure (d :: Day)
        Nothing -> die "Invalid date format. Expected YYYY-MM-DD."

      postingList <- parsePostings postingArgs
      postings <- case NonEmpty.nonEmpty postingList of
        Just ps -> pure ps
        Nothing -> die "At least one posting is required."

      let intent = ActualEditIntent date (T.pack desc) postings

      existingSource <- TIO.readFile journalFile
      case prepareActualAppend existingSource intent of
        Left errs -> do
          die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview -> do
          TIO.putStrLn "--- Preview ---"
          TIO.putStr (HKernel.Editor.ActualAppend.candidateBlock preview)
          TIO.putStrLn "---------------"

          if commitFlag
            then do
              let writeIntent = WriteIntent
                    { targetFilePath = journalFile
                    , expectedOldBytes = existingSource
                    , candidateNewBytes = HKernel.Editor.ActualAppend.candidateCompleteSource preview
                    }
              writeRes <- publishActualAppend writeIntent
              case writeRes of
                Right () -> TIO.putStrLn "Successfully appended to journal."
                Left err -> die $ "Write failed: " <> show err
            else do
              TIO.putStrLn "Run with --commit to apply changes."

    ("reverse":journalFile:targetIdStr:dateStr:descWords) -> do
      let desc = unwords descWords
      date <- case parseTimeM True defaultTimeLocale "%Y-%m-%d" dateStr of
        Just d -> pure (d :: Day)
        Nothing -> die "Invalid date format. Expected YYYY-MM-DD."
      
      targetId <- either (die . show) pure (mkActualTransactionId (T.pack targetIdStr))
      
      let intent = ActualReverseIntent targetId date (T.pack desc)
      
      existingSource <- TIO.readFile journalFile
      case prepareActualReverse existingSource intent of
        Left errs -> do
          die $ "Validation errors:\n" <> unlines (map show (NonEmpty.toList errs))
        Right preview -> do
          TIO.putStrLn "--- Preview ---"
          TIO.putStr (HKernel.Editor.ActualReverse.candidateBlock preview)
          TIO.putStrLn "---------------"

          if commitFlag
            then do
              let writeIntent = WriteIntent
                    { targetFilePath = journalFile
                    , expectedOldBytes = existingSource
                    , candidateNewBytes = HKernel.Editor.ActualReverse.candidateCompleteSource preview
                    }
              writeRes <- publishActualAppend writeIntent
              case writeRes of
                Right () -> TIO.putStrLn "Successfully reversed in journal."
                Left err -> die $ "Write failed: " <> show err
            else do
              TIO.putStrLn "Run with --commit to apply changes."

    _ -> die "Usage:\n  h-kernel-editor-cli append <journal.txt> <YYYY-MM-DD> <desc> [<acct> <qty> <comm> ...] [--commit]\n  h-kernel-editor-cli reverse <journal.txt> <event-id> <YYYY-MM-DD> <desc...> [--commit]"
