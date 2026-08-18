{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Brick
import Brick.Widgets.Border (borderWithLabel)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)

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
  , overviewPlanCount :: Int
  , overviewEnvelopeAttention :: Int
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

attentionAttr :: AttrName
attentionAttr = attrName "attention"

mutedAttr :: AttrName
mutedAttr = attrName "muted"

drawUI :: HomeState -> Widget Name
drawUI state =
  vBox
    [ withAttr mutedAttr
        (strWrap "Interaction shell only · representative values · no Household data loaded")
    , padTop (Pad 1) (drawOverview state)
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
    available (countText (overviewActualCount overview) "transaction")
  Plans ->
    available (countText (overviewPlanCount overview) "open plan")
  Envelopes
    | overviewEnvelopeAttention overview == 0 -> available "no attention"
    | otherwise -> attention
        (countText (overviewEnvelopeAttention overview) "attention item")
  Accounts ->
    available (countText (overviewAccountCount overview) "declared account")
  Issues ->
    let (openCount, closedCount) = overviewIssueCounts overview
    in if openCount == 0
        then available (T.pack (show closedCount) <> " closed")
        else attention
          (T.pack (show openCount) <> " open  ·  "
            <> T.pack (show closedCount) <> " closed")
  Reports -> available "surface available"
  Settings -> available "configuration available"
  where
    available summary = ("✓", availableAttr, summary)
    attention summary = ("!", attentionAttr, summary)

drawDetail :: HomeState -> Widget Name
drawDetail state =
  borderWithLabel (txt ("Selected  ·  " <> sectionLabel selected))
    (padAll 1 (vBox (sectionDetail overview selected)))
  where
    overview = homeOverview state
    selected = homeSelectedSection state

sectionDetail :: Overview -> Section -> [Widget Name]
sectionDetail overview section =
  detail : [withAttr mutedAttr demoNote]
  where
    detail = case section of
      Actual -> txtWrap
        (T.pack (show (overviewActualCount overview))
          <> " transactions are visible at a glance.")
      Plans -> txtWrap
        (T.pack (show (overviewPlanCount overview))
          <> " Plans are open at the observation day.")
      Envelopes -> txtWrap
        (T.pack (show (overviewEnvelopeAttention overview))
          <> " Envelope attention items are visible without opening a report.")
      Accounts -> txtWrap
        (T.pack (show (overviewAccountCount overview))
          <> " Accounts are represented by one compact status row.")
      Issues ->
        let (openCount, closedCount) = overviewIssueCounts overview
        in txtWrap
          ("Open: " <> T.pack (show openCount)
            <> "   Closed: " <> T.pack (show closedCount))
      Reports -> strWrap
        "Report availability can live in the overview without turning Home into the report itself."
      Settings -> strWrap
        "Configuration can be reachable while remaining visually quiet."
    demoNote = strWrap
      "Representative value only. This prototype judges density, selection and drill-down grammar, not Household semantics."

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
        , (attentionAttr, fg V.yellow)
        , (mutedAttr, V.withStyle V.defAttr V.dim)
        ])
  }

demoOverview :: Day -> Overview
demoOverview observedOn = Overview
  { overviewObservedOn = observedOn
  , overviewActualCount = 24
  , overviewPlanCount = 4
  , overviewEnvelopeAttention = 2
  , overviewAccountCount = 12
  , overviewIssueCounts = (1, 8)
  }

main :: IO ()
main = do
  observedOn <- localDay . zonedTimeToLocalTime <$> getZonedTime
  let initialState = HomeState
        { homeSelectedSection = Actual
        , homeOverview = demoOverview observedOn
        }
      buildVty = do
        vty <- mkVty V.defaultConfig
        V.setMode (V.outputIface vty) V.Mouse True
        pure vty
  initialVty <- buildVty
  _ <- customMain initialVty buildVty Nothing app initialState
  pure ()
