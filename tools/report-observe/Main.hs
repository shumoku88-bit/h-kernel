{-# LANGUAGE OverloadedStrings #-}

-- | Measure the report work that matters around one admitted Household
-- observation without introducing a benchmark framework or mutable cache.
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (replicateM)
import Data.IORef (IORef, newIORef, readIORef)
import Data.List (sort)
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

data Sample = Sample
  { sampleNanoseconds :: Word64
  , sampleRenderedLength :: Int
  }

data Summary = Summary
  { summaryAverageMs :: Double
  , summaryMedianMs :: Double
  , summaryMinimumMs :: Double
  , summaryMaximumMs :: Double
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

  -- Force one complete combined report before the repeated observations. This
  -- gives retained-render the same already-observed report model that #135 now
  -- keeps in AppContext, while each render call itself is still executed anew.
  _ <- forceRendered prepared

  stateRef <- newIORef initialState
  preparedRef <- newIORef prepared

  loadSamples <- replicateM runs
    (timedSample (loadPrepareRender root today))
  rebuildSamples <- replicateM runs
    (timedSample (rebuildRender stateRef today))
  retainedSamples <- replicateM runs
    (timedSample (retainedRender preparedRef))

  let loadSummary = summarize loadSamples
      rebuildSummary = summarize rebuildSamples
      retainedSummary = summarize retainedSamples
      projectionDelta = summaryAverageMs rebuildSummary
        - summaryAverageMs retainedSummary

  putStrLn "h-kernel report observation benchmark"
  putStrLn ("observation-day: " <> show today)
  putStrLn ("runs: " <> show runs)
  putStrLn ""
  printSummary "load+project+render" loadSummary
  printSummary "rebuild+render" rebuildSummary
  printSummary "retained-render" retainedSummary
  printf "projection-placement delta: %.3f ms average\n" projectionDelta
  putStrLn ""
  putStrLn "Interpretation:"
  putStrLn "  load+project+render  canonical TUI observation load plus first combined report"
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
  -- Reading through IO prevents the benchmark loop from turning the immutable
  -- Household value into one shared rebuild thunk across samples.
  state <- readIORef stateRef
  report <- prepareOrDie day state
  forceRendered report

retainedRender :: IORef PreparedReport -> IO Int
retainedRender preparedRef = do
  -- The model is intentionally retained, matching AppContext after #135. The
  -- Text renderer is called again for every sample rather than caching output.
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
      ("Household report surface failed: "
        <> show (NonEmpty.toList errors))
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

timedSample :: IO Int -> IO Sample
timedSample action = do
  started <- getMonotonicTimeNSec
  renderedLength <- action
  finished <- getMonotonicTimeNSec
  pure Sample
    { sampleNanoseconds = finished - started
    , sampleRenderedLength = renderedLength
    }

summarize :: [Sample] -> Summary
summarize samples =
  let lengths = map sampleRenderedLength samples
      firstLength = case lengths of
        [] -> error "summarize: empty samples"
        value : _ -> value
      _consistentLength
        | all (== firstLength) lengths = ()
        | otherwise = error "report rendering changed length between samples"
      values = sort (map (nanosecondsToMilliseconds . sampleNanoseconds) samples)
      count = length values
      total = sum values
      medianValue
        | odd count = values !! (count `div` 2)
        | otherwise =
            let upper = count `div` 2
            in (values !! (upper - 1) + values !! upper) / 2
  in _consistentLength `seq` Summary
      { summaryAverageMs = total / fromIntegral count
      , summaryMedianMs = medianValue
      , summaryMinimumMs = head values
      , summaryMaximumMs = last values
      }

nanosecondsToMilliseconds :: Word64 -> Double
nanosecondsToMilliseconds value = fromIntegral value / 1000000

printSummary :: String -> Summary -> IO ()
printSummary label value =
  printf "%s: average=%.3fms median=%.3fms min=%.3fms max=%.3fms\n"
    label
    (summaryAverageMs value)
    (summaryMedianMs value)
    (summaryMinimumMs value)
    (summaryMaximumMs value)

parsePositiveInt :: String -> Maybe Int
parsePositiveInt value = case reads value of
  [(number, "")] | number > 0 -> Just number
  _ -> Nothing

usage :: IO a
usage = die "Usage: cabal run exe:report-observe -- <household-root> [runs]"

die :: String -> IO a
die message = putStrLn message >> exitFailure
