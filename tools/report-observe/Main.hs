{-# LANGUAGE OverloadedStrings #-}

-- | Measure report work around one admitted Household observation without
-- introducing a benchmark framework or mutable report cache.
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (replicateM)
import Data.IORef (IORef, newIORef, readIORef)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import Text.Printf (printf)

import HKernel.Actual.Journal (actualJournalValue)
import HKernel.Application.Config (HouseholdRoot, mkHouseholdRoot)
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Report (ReportBook, reportBookWithPlan)
import HKernel.Report.Config
  ( reportConfigurationPlan
  , reportConfigurationPresentation
  )
import HKernel.Report.Plan (resolveReportPlan)
import HKernel.Report.Presentation (PresentationConfig)
import HKernel.Spike.HouseholdReport (HouseholdReportSurface)
import HKernel.Spike.HouseholdReport.Render
  ( renderReportBookWithHouseholdPresentation
  )

data PreparedReport = PreparedReport
  { preparedPresentation :: PresentationConfig
  , preparedBook :: ReportBook
  , preparedSurface :: HouseholdReportSurface
  }

main :: IO ()
main = do
  args <- getArgs
  (rootPath, runs) <- case args of
    [path] -> pure (path, 10)
    [path, runsText] -> case parsePositiveInt runsText of
      Just value -> pure (path, value)
      Nothing -> usage
    _ -> usage

  root <- case mkHouseholdRoot rootPath of
    Left err -> die ("invalid Household root: " <> show err)
    Right value -> pure value

  today <- localDay . zonedTimeToLocalTime <$> getZonedTime
  initialState <- loadState root
  prepared <- prepareOrDie today initialState

  -- Force one complete combined report before repeated observations. The
  -- retained case therefore starts with the same already-observed report model
  -- that #135 now keeps in AppContext, while Text rendering is invoked anew.
  _ <- forceRendered prepared

  stateRef <- newIORef initialState
  preparedRef <- newIORef prepared

  loadSamples <- replicateM runs
    (timed (loadPrepareRender root today))
  rebuildSamples <- replicateM runs
    (timed (rebuildRender stateRef today))
  retainedSamples <- replicateM runs
    (timed (retainedRender preparedRef))

  putStrLn "h-kernel report observation benchmark"
  putStrLn ("observation-day: " <> show today)
  putStrLn ("runs: " <> show runs)
  putStrLn ""
  printSamples "load+project+render" loadSamples
  printSamples "rebuild+render" rebuildSamples
  printSamples "retained-render" retainedSamples
  printf "projection-placement delta: %.3f ms average\n"
    (averageMs rebuildSamples - averageMs retainedSamples)
  putStrLn ""
  putStrLn "Interpretation:"
  putStrLn "  load+project+render  canonical Household observation load plus combined report"
  putStrLn "  rebuild+render       old redraw shape: rebuild report projections, then render"
  putStrLn "  retained-render      #135 shape: reuse report projections, then render"
  putStrLn "  delta                approximate projection work removed from one redraw"

loadPrepareRender :: HouseholdRoot -> Day -> IO Int
loadPrepareRender root day = do
  state <- loadState root
  report <- prepareOrDie day state
  forceRendered report

rebuildRender :: IORef HouseholdState -> Day -> IO Int
rebuildRender stateRef day = do
  -- Read through IO so repeated samples do not collapse into one shared rebuild
  -- thunk merely because the admitted Household value is immutable.
  state <- readIORef stateRef
  report <- prepareOrDie day state
  forceRendered report

retainedRender :: IORef PreparedReport -> IO Int
retainedRender preparedRef = do
  -- The report model is retained, matching AppContext after #135. Rendered Text
  -- itself is not cached.
  report <- readIORef preparedRef
  forceRendered report

loadState :: HouseholdRoot -> IO HouseholdState
loadState root = do
  result <- loadCanonicalHouseholdWriteSnapshot root
  case result of
    Left errors -> die
      ("canonical Household load failed:\n"
        <> unlines (map (("  - " <>) . show) (NonEmpty.toList errors)))
    Right snapshot -> pure (householdWriteSnapshotState snapshot)

prepareOrDie :: Day -> HouseholdState -> IO PreparedReport
prepareOrDie day state = case prepareReport day state of
  Left err -> die err
  Right value -> pure value

prepareReport :: Day -> HouseholdState -> Either String PreparedReport
prepareReport day state = do
  let journal = actualJournalValue (householdStateActualJournal state)
      config = householdStateReportConfig state
      presentation = reportConfigurationPresentation config
  plan <- case resolveReportPlan day journal (reportConfigurationPlan config) of
    Left err -> Left ("report plan resolution failed: " <> show err)
    Right value -> Right value
  surface <- case buildHouseholdReportSurfaceFromHousehold day state of
    Left errors -> Left
      ("Household report surface failed: " <> show (NonEmpty.toList errors))
    Right value -> Right value
  pure PreparedReport
    { preparedPresentation = presentation
    , preparedBook = reportBookWithPlan plan journal
    , preparedSurface = surface
    }

forceRendered :: PreparedReport -> IO Int
forceRendered report = evaluate
  (T.length
    (renderReportBookWithHouseholdPresentation
      (preparedPresentation report)
      (preparedBook report)
      (preparedSurface report)))

timed :: IO Int -> IO Word64
timed action = do
  started <- getMonotonicTimeNSec
  _ <- action
  finished <- getMonotonicTimeNSec
  pure (finished - started)

averageMs :: [Word64] -> Double
averageMs values =
  sum (map nanosecondsToMilliseconds values) / fromIntegral (length values)

printSamples :: String -> [Word64] -> IO ()
printSamples label values =
  printf "%s: runs=%d average=%.3fms min=%.3fms max=%.3fms\n"
    label
    (length values)
    (averageMs values)
    (nanosecondsToMilliseconds (minimum values))
    (nanosecondsToMilliseconds (maximum values))

nanosecondsToMilliseconds :: Word64 -> Double
nanosecondsToMilliseconds value = fromIntegral value / 1000000

parsePositiveInt :: String -> Maybe Int
parsePositiveInt value = case reads value of
  [(number, "")] | number > 0 -> Just number
  _ -> Nothing

usage :: IO a
usage = die "Usage: cabal run exe:report-observe -- <household-root> [runs]"

die :: String -> IO a
die message = putStrLn message >> exitFailure
