{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Brick
import Brick.Widgets.Border (borderWithLabel)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import Graphics.Vty qualified as V
import Graphics.Vty.CrossPlatform (mkVty)
import System.Directory (doesDirectoryExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath (takeDirectory)

import HKernel.Actual.Journal (actualJournalTransactionEntries)
import HKernel.Application.Config (mkHouseholdRoot)
import HKernel.Editor.HouseholdWorkspace
  ( workspaceAccounts
  , workspaceIssueCounts
  )
import HKernel.Household.Application
  ( HouseholdState(..)
  , HouseholdWriteSnapshot(..)
  , buildHouseholdReportSurfaceFromHousehold
  , loadCanonicalHouseholdWriteSnapshot
  )
import HKernel.Plan.Open (resolveOpenPlanTransactionsAt)

data Section
  = Actual
  | Plans
  | Envelopes
  | Accounts
  | Issues
  | Reports
  | Settings
  deriving (Eq, Ord, Show, Enum, Bounded)

data Name = SectionRow Section
  deriving (Eq, Ord, Show)

data Overview = Overview
  { overviewObservedOn :: Day
  , overviewActualCount :: Int
  , overviewPlanCount :: Either Text Int
  , overviewEnvelopeAvailability :: Either Text ()
  , overviewAccountCount :: Int
  , overviewIssueCounts :: (Int, Int)
  }

data HomeState = HomeState
  { homeSelectedSection :: Section
  , homeOverview :: Overview
  }

sections :: [Section]
sections = [minBound .. maxBound]

selectedAttr :: AttrName
selectedAttr = attrName "selected"

availableAttr :: AttrName
availableAttr = attrName "available"

unavailableAttr :: AttrName
unavailableAttr = attrName "unavailable"

mutedAttr :: AttrName
mutedAttr = attrName "muted"

drawUI :: HomeState -> Widget Name
drawUI state =
  vBox
    [ drawOverview state
    , padTop (Pad 1) (drawDetail state)
    , padTop (Pad 1)
        (withAttr mutedAttr
          (strWrap "[Up/Down or j/k] Select   [mouse] Select   [q] Quit"))
    ]

drawOverview :: HomeState -> Widget Name
drawOverview state =
  borderWithLabel
      (txt ("h-kernel Household  ·  " <> T.pack (show observedOn)))
    (padAll 1 (vBox (map (drawSectionRow state) sections)))
  where
    observedOn = overviewObservedOn (homeOverview state)

drawSectionRow :: HomeState -> Section -> Widget Name
drawSectionRow state section =
  clickable (SectionRow section) rendered
  where
    overview = homeOverview state
    (glyph, statusAttr, summary) = sectionStatus overview section
    row = hBox
      [ hLimit 3 (withAttr statusAttr (txt glyph))
      , hLimit 14 (txt (sectionLabel section))
      , padLeft (Pad 2) (txt summary)
      ]
    rendered
      | homeSelectedSection state == section = withAttr selectedAttr row
      | otherwise = row

sectionStatus :: Overview -> Section -> (Text, AttrName, Text)
sectionStatus overview section = case section of
  Actual ->
    available (countText (overviewActualCount overview) "admitted transaction")
  Plans -> case overviewPlanCount overview of
    Left _ -> unavailable "observation unavailable"
    Right count -> available (countText count "open plan")
  Envelopes -> case overviewEnvelopeAvailability overview of
    Left _ -> unavailable "household observation unavailable"
    Right () -> available "household observation available"
  Accounts ->
    available (countText (overviewAccountCount overview) "declared account")
  Issues ->
    let (openCount, closedCount) = overviewIssueCounts overview
    in available
        (T.pack (show openCount) <> " open  ·  "
          <> T.pack (show closedCount) <> " closed")
  Reports -> case overviewEnvelopeAvailability overview of
    Left _ -> unavailable "household report surface unavailable"
    Right () -> available "household report surface available"
  Settings -> available "canonical configuration loaded"
  where
    available summary = ("✓", availableAttr, summary)
    unavailable summary = ("×", unavailableAttr, summary)

drawDetail :: HomeState -> Widget Name
drawDetail state =
  borderWithLabel (txt ("Selected  ·  " <> sectionLabel selected))
    (padAll 1 (vBox (sectionDetail overview selected)))
  where
    overview = homeOverview state
    selected = homeSelectedSection state

sectionDetail :: Overview -> Section -> [Widget Name]
sectionDetail overview section = case section of
  Actual ->
    [ txtWrap
        ("The admitted Actual journal currently contains "
          <> T.pack (show (overviewActualCount overview))
          <> " transactions.")
    , strWrap "The prototype only observes it; it does not write or reinterpret Actual facts."
    ]
  Plans -> case overviewPlanCount overview of
    Left reason ->
      [ withAttr unavailableAttr (strWrap "Open Plan observation is unavailable.")
      , txtWrap (T.take 400 reason)
      ]
    Right count ->
      [ txtWrap
          (T.pack (show count)
            <> " Plans are open at this observation day.")
      , strWrap "The count comes from the existing typed Plan observation."
      ]
  Envelopes -> case overviewEnvelopeAvailability overview of
    Left reason ->
      [ withAttr unavailableAttr (strWrap "Household observation is unavailable.")
      , txtWrap (T.take 400 reason)
      ]
    Right () ->
      [ strWrap "The existing Household report surface is available."
      , strWrap "No new Envelope state or fallback is introduced for this UI experiment."
      ]
  Accounts ->
    [ txtWrap
        (T.pack (show (overviewAccountCount overview))
          <> " Accounts are declared in the admitted registry.")
    ]
  Issues ->
    let (openCount, closedCount) = overviewIssueCounts overview
    in [ txtWrap
          ("Open: " <> T.pack (show openCount)
            <> "   Closed: " <> T.pack (show closedCount))
       , strWrap "Status is shown without turning presentation attention into a new Issue fact."
       ]
  Reports -> case overviewEnvelopeAvailability overview of
    Left reason ->
      [ withAttr unavailableAttr (strWrap "Household report surface is unavailable.")
      , txtWrap (T.take 400 reason)
      ]
    Right () ->
      [ strWrap "The admitted Household can project its current report surface."
      , strWrap "A later experiment can put report-specific state in this row without owning report semantics."
      ]
  Settings ->
    [ strWrap "Canonical Household sources and configuration were admitted before this screen started."
    , strWrap "This row is presentation only; it is not a second configuration authority."
    ]

countText :: Int -> Text -> Text
countText count noun =
  T.pack (show count) <> " " <> noun <> if count == 1 then "" else "s"

sectionLabel :: Section -> Text
sectionLabel section = case section of
  Actual -> "Actual"
  Plans -> "Plans"
  Envelopes -> "Envelopes"
  Accounts -> "Accounts"
  Issues -> "Issues"
  Reports -> "Reports"
  Settings -> "Settings"

moveSelection :: Int -> HomeState -> HomeState
moveSelection delta state =
  state { homeSelectedSection = toEnum nextIndex }
  where
    sectionCount = length sections
    currentIndex = fromEnum (homeSelectedSection state)
    nextIndex = (currentIndex + delta) `mod` sectionCount

handleEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleEvent event = case event of
  MouseDown (SectionRow section) V.BLeft _ _ ->
    modify (\state -> state { homeSelectedSection = section })
  VtyEvent (V.EvKey V.KUp []) -> modify (moveSelection (-1))
  VtyEvent (V.EvKey V.KDown []) -> modify (moveSelection 1)
  VtyEvent (V.EvKey (V.KChar 'k') []) -> modify (moveSelection (-1))
  VtyEvent (V.EvKey (V.KChar 'K') []) -> modify (moveSelection (-1))
  VtyEvent (V.EvKey (V.KChar 'j') []) -> modify (moveSelection 1)
  VtyEvent (V.EvKey (V.KChar 'J') []) -> modify (moveSelection 1)
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KEsc []) -> halt
  _ -> pure ()

app :: App HomeState () Name
app = App
  { appDraw = \state -> [drawUI state]
  , appChooseCursor = neverShowCursor
  , appHandleEvent = handleEvent
  , appStartEvent = pure ()
  , appAttrMap = const
      (attrMap V.defAttr
        [ (selectedAttr, V.black `on` V.white)
        , (availableAttr, fg V.green)
        , (unavailableAttr, fg V.red)
        , (mutedAttr, V.withStyle V.defAttr V.dim)
        ])
  }

buildOverview :: Day -> HouseholdState -> Overview
buildOverview observedOn household =
  Overview
    { overviewObservedOn = observedOn
    , overviewActualCount =
        length
          (actualJournalTransactionEntries
            (householdStateActualJournal household))
    , overviewPlanCount = case resolveOpenPlanTransactionsAt
        observedOn
        (householdStatePlanJournal household)
        (householdStateActualJournal household) of
        Left errors -> Left (T.pack (show errors))
        Right plans -> Right (length plans)
    , overviewEnvelopeAvailability =
        case buildHouseholdReportSurfaceFromHousehold observedOn household of
          Left errors -> Left (T.pack (show errors))
          Right _ -> Right ()
    , overviewAccountCount =
        length (workspaceAccounts (householdStateAccountsRegistry household))
    , overviewIssueCounts = workspaceIssueCounts (householdStateIssues household)
    }

main :: IO ()
main = do
  observedOn <- localDay . zonedTimeToLocalTime <$> getZonedTime
  arguments <- getArgs
  case arguments of
    [path] -> do
      pathIsDirectory <- doesDirectoryExist path
      let rootDir
            | pathIsDirectory = path
            | otherwise = takeDirectory path
          rootPath = if rootDir == "" then "." else rootDir
      root <- case mkHouseholdRoot rootPath of
        Left err -> die ("Invalid household root: " <> show err)
        Right value -> pure value
      householdResult <- loadCanonicalHouseholdWriteSnapshot root
      snapshot <- case householdResult of
        Left errors -> die
          ("Failed to load canonical Household:\n"
            <> unlines (map show (NonEmpty.toList errors)))
        Right value -> pure value
      let household = householdWriteSnapshotState snapshot
          initialState = HomeState
            { homeSelectedSection = Actual
            , homeOverview = buildOverview observedOn household
            }
          buildVty = do
            vty <- mkVty V.defaultConfig
            V.setMode (V.outputIface vty) V.Mouse True
            pure vty
      initialVty <- buildVty
      _ <- customMain initialVty buildVty Nothing app initialState
      pure ()
    _ -> die "Usage: h-kernel-ghcup-home <household-root-or-actual.journal>"
