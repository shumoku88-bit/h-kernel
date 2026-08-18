{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Brick
import Brick.Widgets.Border (borderWithLabel)
import Control.Concurrent (forkOS, newEmptyMVar, putMVar, takeMVar)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar
  ( Day
  , addDays
  , fromGregorian
  , gregorianMonthLength
  , toGregorian
  )
import Data.Time.Calendar.WeekDate (toWeekDate)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.LocalTime (getZonedTime, localDay, zonedTimeToLocalTime)
import qualified Graphics.Vty as V
import Graphics.Vty.CrossPlatform (mkVty)
import System.Environment (getArgs)

data Section
  = Actual
  | Plans
  | Envelopes
  | Accounts
  | Issues
  | Reports
  | Settings
  deriving (Eq, Ord, Show, Enum, Bounded)

data Name
  = SectionRow Section
  | CalendarDay Day
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
  , homeSelectedDay :: Day
  , homeOverview :: Overview
  }

sections :: [Section]
sections = [minBound .. maxBound]

sectionSelectedAttr :: AttrName
sectionSelectedAttr = attrName "sectionSelected"

daySelectedAttr :: AttrName
daySelectedAttr = attrName "daySelected"

todayAttr :: AttrName
todayAttr = attrName "today"

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
        (strWrap "Shell experiment · representative values · no Household data loaded")
    , padTop (Pad 1)
        (hBox
          [ hLimit 30 (drawRail state)
          , padLeft (Pad 1) (drawSurface state)
          ])
    , padTop (Pad 1)
        (withAttr mutedAttr
          (strWrap
            "[Up/Down or j/k] Section   [Left/Right or h/l] Day   [t] Today   [mouse] Select   [q] Quit"))
    ]

drawRail :: HomeState -> Widget Name
drawRail state =
  vBox
    [ drawCalendar state
    , padTop (Pad 1) (drawSectionRail state)
    ]

drawCalendar :: HomeState -> Widget Name
drawCalendar state =
  borderWithLabel (txt monthLabel)
    (padAll 1 (vBox (weekdayHeader : map drawWeek weeks)))
  where
    selectedDay = homeSelectedDay state
    observedOn = overviewObservedOn (homeOverview state)
    (year, month, _) = toGregorian selectedDay
    monthLabel = T.pack (formatTime defaultTimeLocale "%b %Y" selectedDay)
    monthLength = gregorianMonthLength year month
    firstDay = fromGregorian year month 1
    (_, _, firstWeekday) = toWeekDate firstDay
    days = [fromGregorian year month day | day <- [1 .. monthLength]]
    leading = replicate (firstWeekday - 1) Nothing
    cells = leading ++ map Just days
    trailing = replicate ((7 - length cells `mod` 7) `mod` 7) Nothing
    weeks = chunksOf 7 (cells ++ trailing)
    weekdayHeader = hBox (map (hLimit 3 . txt) ["Mo ", "Tu ", "We ", "Th ", "Fr ", "Sa ", "Su "])
    drawWeek = hBox . map drawCell
    drawCell Nothing = hLimit 3 (str "   ")
    drawCell (Just day) =
      let (_, _, dayOfMonth) = toGregorian day
          label = T.justifyRight 2 ' ' (T.pack (show dayOfMonth)) <> " "
          base = clickable (CalendarDay day) (hLimit 3 (txt label))
      in if day == selectedDay
          then withAttr daySelectedAttr base
          else if day == observedOn
            then withAttr todayAttr base
            else base

drawSectionRail :: HomeState -> Widget Name
drawSectionRail state =
  borderWithLabel (str "Household")
    (padAll 1 (vBox (map (drawSectionRow state) sections)))

drawSectionRow :: HomeState -> Section -> Widget Name
drawSectionRow state section =
  clickable (SectionRow section) rendered
  where
    overview = homeOverview state
    (glyph, statusAttr, summary) = sectionStatus overview section
    row = hBox
      [ hLimit 2 (withAttr statusAttr (txt glyph))
      , hLimit 11 (txt (sectionLabel section))
      , padLeft (Pad 1) (txt summary)
      ]
    rendered
      | homeSelectedSection state == section = withAttr sectionSelectedAttr row
      | otherwise = row

sectionStatus :: Overview -> Section -> (Text, AttrName, Text)
sectionStatus overview section = case section of
  Actual -> available (T.pack (show (overviewActualCount overview)) <> " rec")
  Plans -> available (T.pack (show (overviewPlanCount overview)) <> " open")
  Envelopes
    | overviewEnvelopeAttention overview == 0 -> available "clear"
    | otherwise -> attention
        (T.pack (show (overviewEnvelopeAttention overview)) <> " attn")
  Accounts -> available (T.pack (show (overviewAccountCount overview)))
  Issues ->
    let (openCount, _) = overviewIssueCounts overview
    in if openCount == 0
        then available "clear"
        else attention (T.pack (show openCount) <> " open")
  Reports -> available "ready"
  Settings -> available "ready"
  where
    available summary = ("✓", availableAttr, summary)
    attention summary = ("!", attentionAttr, summary)

drawSurface :: HomeState -> Widget Name
drawSurface state =
  borderWithLabel
      (txt (sectionLabel selected <> "  ·  " <> dayText selectedDay))
    (padAll 1
      (vBox
        ( [ withAttr mutedAttr
              (txtWrap
                "The rail chooses what to observe; the mini calendar chooses when. This pane is the selected surface.")
          , str " "
          ]
          ++ sectionSurface overview selectedDay selected
          ++ [ str " "
             , withAttr mutedAttr
                 (strWrap
                   "Representative values only. A production version would project admitted AppContext data into this surface.")
             ]
        )))
  where
    overview = homeOverview state
    selected = homeSelectedSection state
    selectedDay = homeSelectedDay state

sectionSurface :: Overview -> Day -> Section -> [Widget Name]
sectionSurface overview selectedDay section = case section of
  Actual ->
    [ heading "Actual on selected day"
    , txtWrap ("Observation date: " <> dayText selectedDay)
    , txtWrap
        ("Recorded in representative overview: "
          <> T.pack (show (overviewActualCount overview)) <> " transactions")
    , str " "
    , heading "Recent"
    , str "  12:10  Grocery       -1,250 JPY"
    , str "  09:20  Mobile plan     -440 JPY"
    ]
  Plans ->
    [ heading "Open plans"
    , txtWrap
        (T.pack (show (overviewPlanCount overview))
          <> " plans remain open at the observation boundary")
    , str " "
    , str "  2026-08-20  Internet"
    , str "  2026-08-25  Investment"
    , str "  2026-09-01  Rent"
    ]
  Envelopes ->
    [ heading "Envelope observation"
    , txtWrap
        (T.pack (show (overviewEnvelopeAttention overview))
          <> " attention items")
    , str " "
    , str "  Food          remaining 31,240 JPY"
    , str "  Daily         remaining  8,400 JPY"
    , withAttr attentionAttr (str "  Utilities     attention")
    , str " "
    , withAttr mutedAttr
        (strWrap "A real surface could expose remaining, change and provenance without moving those semantics into Brick.")
    ]
  Accounts ->
    [ heading "Accounts"
    , txtWrap
        (T.pack (show (overviewAccountCount overview))
          <> " declared accounts")
    , str " "
    , str "  Assets:Bank"
    , str "  Assets:Savings"
    , str "  Expenses:Food"
    , str "  Expenses:Utilities"
    ]
  Issues ->
    let (openCount, closedCount) = overviewIssueCounts overview
    in [ heading "Issues"
       , txtWrap
           ("Open: " <> T.pack (show openCount)
             <> "   Closed: " <> T.pack (show closedCount))
       , str " "
       , withAttr attentionAttr (str "  due soon   Review subscription")
       , str "  open       Replace Wi-Fi equipment"
       ]
  Reports ->
    [ heading "Reports"
    , str "  Trial balance"
    , str "  Balance sheet"
    , str "  Profit and loss"
    , str "  Envelope change"
    , str "  Provenance / explain"
    , str " "
    , withAttr mutedAttr
        (strWrap "The selected calendar day would become the observation coordinate for temporal reports.")
    ]
  Settings ->
    [ heading "Settings"
    , str "  Household configuration"
    , str "  Report presentation"
    , str "  Calendar markers"
    , str "  Source paths"
    ]
  where
    heading label = withAttr availableAttr (txt label)

dayText :: Day -> Text
dayText = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"

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

moveSection :: Int -> HomeState -> HomeState
moveSection delta state =
  state { homeSelectedSection = toEnum nextIndex }
  where
    sectionCount = length sections
    currentIndex = fromEnum (homeSelectedSection state)
    nextIndex = (currentIndex + delta) `mod` sectionCount

moveDay :: Integer -> HomeState -> HomeState
moveDay delta state =
  state { homeSelectedDay = addDays delta (homeSelectedDay state) }

selectToday :: HomeState -> HomeState
selectToday state =
  state { homeSelectedDay = overviewObservedOn (homeOverview state) }

handleEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleEvent event = case event of
  MouseDown (SectionRow section) V.BLeft _ _ ->
    modify (\state -> state { homeSelectedSection = section })
  MouseDown (CalendarDay day) V.BLeft _ _ ->
    modify (\state -> state { homeSelectedDay = day })
  VtyEvent (V.EvKey V.KUp []) -> modify (moveSection (-1))
  VtyEvent (V.EvKey V.KDown []) -> modify (moveSection 1)
  VtyEvent (V.EvKey (V.KChar 'k') []) -> modify (moveSection (-1))
  VtyEvent (V.EvKey (V.KChar 'K') []) -> modify (moveSection (-1))
  VtyEvent (V.EvKey (V.KChar 'j') []) -> modify (moveSection 1)
  VtyEvent (V.EvKey (V.KChar 'J') []) -> modify (moveSection 1)
  VtyEvent (V.EvKey V.KLeft []) -> modify (moveDay (-1))
  VtyEvent (V.EvKey V.KRight []) -> modify (moveDay 1)
  VtyEvent (V.EvKey (V.KChar 'h') []) -> modify (moveDay (-1))
  VtyEvent (V.EvKey (V.KChar 'H') []) -> modify (moveDay (-1))
  VtyEvent (V.EvKey (V.KChar 'l') []) -> modify (moveDay 1)
  VtyEvent (V.EvKey (V.KChar 'L') []) -> modify (moveDay 1)
  VtyEvent (V.EvKey (V.KChar 't') []) -> modify selectToday
  VtyEvent (V.EvKey (V.KChar 'T') []) -> modify selectToday
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
        [ (sectionSelectedAttr, V.black `on` V.white)
        , (daySelectedAttr, V.black `on` V.cyan)
        , (todayAttr, V.withStyle V.defAttr V.bold)
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

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf width values =
  let (chunk, rest) = splitAt width values
  in chunk : chunksOf width rest

runSmoke :: IO ()
runSmoke = do
  done <- newEmptyMVar
  _ <- forkOS (putMVar done ())
  takeMVar done

runTui :: IO ()
runTui = do
  observedOn <- localDay . zonedTimeToLocalTime <$> getZonedTime
  let initialState = HomeState
        { homeSelectedSection = Actual
        , homeSelectedDay = observedOn
        , homeOverview = demoOverview observedOn
        }
      buildVty = do
        vty <- mkVty V.defaultConfig
        V.setMode (V.outputIface vty) V.Mouse True
        pure vty
  initialVty <- buildVty
  _ <- customMain initialVty buildVty Nothing app initialState
  pure ()

main :: IO ()
main = do
  args <- getArgs
  if "--smoke" `elem` args
    then runSmoke
    else runTui
