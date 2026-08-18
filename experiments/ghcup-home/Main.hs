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

data ShellFocus
  = CalendarFocus
  | SectionFocus
  | SurfaceFocus
  deriving (Eq, Show)

data Name
  = SectionRow Section
  | CalendarDay Day
  | SurfacePane
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
  , homeTemporalCursorDay :: Day
  , homeFocus :: ShellFocus
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

focusAttr :: AttrName
focusAttr = attrName "focus"

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
        (strWrap "Shell experiment · current observation stays current · calendar is a temporal cursor")
    , padTop (Pad 1)
        (hBox
          [ hLimit 30 (drawRail state)
          , padLeft (Pad 1) (drawSurface state)
          ])
    , padTop (Pad 1) (drawKeyHelp state)
    ]

drawKeyHelp :: HomeState -> Widget Name
drawKeyHelp state =
  withAttr mutedAttr (strWrap help)
  where
    help = case homeFocus state of
      CalendarFocus ->
        "Calendar focus: [arrows / h j k l] Move cursor   [t] Today   [Tab] Next area   [mouse] Focus/select   [q/Esc] Quit"
      SectionFocus ->
        "Section focus: [Up/Down or j/k] Select   [Right/Enter] Open surface   [Tab] Next area   [mouse] Focus/select   [q/Esc] Quit"
      SurfaceFocus ->
        "Surface focus: [Left] Back to sections   [Tab] Next area   [mouse] Focus   [q/Esc] Quit"

drawRail :: HomeState -> Widget Name
drawRail state =
  vBox
    [ drawCalendar state
    , padTop (Pad 1) (drawSectionRail state)
    ]

drawCalendar :: HomeState -> Widget Name
drawCalendar state =
  borderWithLabel (focusLabel state CalendarFocus monthLabel)
    (padAll 1 (vBox (weekdayHeader : map drawWeek weeks)))
  where
    cursorDay = homeTemporalCursorDay state
    observedOn = overviewObservedOn (homeOverview state)
    (year, month, _) = toGregorian cursorDay
    monthLabel = "Calendar · " <> T.pack (formatTime defaultTimeLocale "%b %Y" cursorDay)
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
      in if day == cursorDay
          then withAttr daySelectedAttr base
          else if day == observedOn
            then withAttr todayAttr base
            else base

drawSectionRail :: HomeState -> Widget Name
drawSectionRail state =
  borderWithLabel
      (focusLabel state SectionFocus
        ("Household · current " <> dayText observedOn))
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
      [ hLimit 2 (withAttr statusAttr (txt glyph))
      , hLimit 11 (txt (sectionLabel section))
      , padLeft (Pad 1) (txt summary)
      ]
    rendered
      | homeSelectedSection state == section = withAttr sectionSelectedAttr row
      | otherwise = row

-- | Rail status belongs to the current admitted observation. Moving the
-- calendar cursor must not quietly turn every status into a historical one.
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
  clickable SurfacePane $
    borderWithLabel
      (focusLabel state SurfaceFocus (surfaceTitle selected cursorDay))
      (padAll 1
        (vBox
          ( [ withAttr mutedAttr
                (txtWrap coordinates)
            , str " "
            ]
            ++ sectionSurface overview cursorDay selected
            ++ [ str " "
               , withAttr mutedAttr
                   (txtWrap temporalNote)
               , withAttr mutedAttr
                   (strWrap
                     "Representative values only. Production would project already-admitted AppContext data here.")
               ]
          )))
  where
    overview = homeOverview state
    observedOn = overviewObservedOn overview
    selected = homeSelectedSection state
    cursorDay = homeTemporalCursorDay state
    coordinates =
      "Current observation: " <> dayText observedOn
        <> "   Calendar cursor: " <> dayText cursorDay
    temporalNote
      | sectionUsesTemporalCursor selected =
          "This surface may use the calendar cursor. The status rail still describes the current observation."
      | otherwise =
          "This surface is not bound to the calendar cursor. Moving through time does not rewrite this section."

focusLabel :: HomeState -> ShellFocus -> Text -> Widget Name
focusLabel state target label
  | homeFocus state == target = withAttr focusAttr (txt ("[" <> label <> "]"))
  | otherwise = txt label

surfaceTitle :: Section -> Day -> Text
surfaceTitle section cursorDay
  | sectionUsesTemporalCursor section =
      sectionLabel section <> " · cursor " <> dayText cursorDay
  | otherwise = sectionLabel section <> " · current"

sectionUsesTemporalCursor :: Section -> Bool
sectionUsesTemporalCursor section = case section of
  Actual -> True
  Plans -> True
  Envelopes -> True
  Accounts -> False
  Issues -> True
  Reports -> True
  Settings -> False

sectionSurface :: Overview -> Day -> Section -> [Widget Name]
sectionSurface overview cursorDay section = case section of
  Actual ->
    [ heading "Actual at temporal cursor"
    , txtWrap ("Cursor date: " <> dayText cursorDay)
    , str " "
    , heading "Representative entries"
    , str "  12:10  Grocery       -1,250 JPY"
    , str "  09:20  Mobile plan     -440 JPY"
    ]
  Plans ->
    [ heading "Plans around temporal cursor"
    , txtWrap ("Cursor date: " <> dayText cursorDay)
    , txtWrap
        ("Current rail observation still has "
          <> T.pack (show (overviewPlanCount overview)) <> " open plans")
    , str " "
    , str "  2026-08-20  Internet"
    , str "  2026-08-25  Investment"
    , str "  2026-09-01  Rent"
    ]
  Envelopes ->
    [ heading "Envelope observation at temporal cursor"
    , txtWrap ("Cursor date: " <> dayText cursorDay)
    , txtWrap
        ("Current rail attention: "
          <> T.pack (show (overviewEnvelopeAttention overview)))
    , str " "
    , str "  Food          remaining 31,240 JPY"
    , str "  Daily         remaining  8,400 JPY"
    , withAttr attentionAttr (str "  Utilities     attention")
    , str " "
    , withAttr mutedAttr
        (strWrap "A real projection could expose remaining, change and provenance at this cursor without making Brick own those semantics.")
    ]
  Accounts ->
    [ heading "Accounts · current registry"
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
    in [ heading "Issues with temporal context"
       , txtWrap ("Cursor date: " <> dayText cursorDay)
       , txtWrap
           ("Current rail status · Open: " <> T.pack (show openCount)
             <> "   Closed: " <> T.pack (show closedCount))
       , str " "
       , withAttr attentionAttr (str "  due soon   Review subscription")
       , str "  open       Replace Wi-Fi equipment"
       ]
  Reports ->
    [ heading "Reports"
    , txtWrap ("Temporal cursor candidate: " <> dayText cursorDay)
    , str " "
    , str "  Trial balance"
    , str "  Balance sheet"
    , str "  Profit and loss"
    , str "  Envelope change"
    , str "  Provenance / explain"
    ]
  Settings ->
    [ heading "Settings · current configuration"
    , str "  Household configuration"
    , str "  Report presentation"
    , str "  Calendar markers"
    , str "  Source paths"
    ]
  where
    heading label = withAttr availableAttr (txt label)

dayText :: Day -> Text
dayText = T.pack . formatTime defaultTimeLocale "%Y-%m-%d"

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

moveTemporalCursor :: Integer -> HomeState -> HomeState
moveTemporalCursor delta state =
  state
    { homeTemporalCursorDay =
        addDays delta (homeTemporalCursorDay state)
    }

selectToday :: HomeState -> HomeState
selectToday state =
  state
    { homeTemporalCursorDay =
        overviewObservedOn (homeOverview state)
    }

nextFocus :: ShellFocus -> ShellFocus
nextFocus focus = case focus of
  CalendarFocus -> SectionFocus
  SectionFocus -> SurfaceFocus
  SurfaceFocus -> CalendarFocus

handleEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleEvent event = case event of
  MouseDown (SectionRow section) V.BLeft _ _ ->
    modify (\state -> state
      { homeSelectedSection = section
      , homeFocus = SectionFocus
      })
  MouseDown (CalendarDay day) V.BLeft _ _ ->
    modify (\state -> state
      { homeTemporalCursorDay = day
      , homeFocus = CalendarFocus
      })
  MouseDown SurfacePane V.BLeft _ _ ->
    modify (\state -> state { homeFocus = SurfaceFocus })
  VtyEvent (V.EvKey (V.KChar '\t') []) ->
    modify (\state -> state { homeFocus = nextFocus (homeFocus state) })
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey (V.KChar 'Q') []) -> halt
  VtyEvent (V.EvKey V.KEsc []) -> halt
  _ -> handleFocusedEvent event

handleFocusedEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleFocusedEvent event = do
  focus <- homeFocus <$> get
  case focus of
    CalendarFocus -> handleCalendarEvent event
    SectionFocus -> handleSectionEvent event
    SurfaceFocus -> handleSurfaceEvent event

handleCalendarEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleCalendarEvent event = case event of
  VtyEvent (V.EvKey V.KLeft []) -> modify (moveTemporalCursor (-1))
  VtyEvent (V.EvKey V.KRight []) -> modify (moveTemporalCursor 1)
  VtyEvent (V.EvKey V.KUp []) -> modify (moveTemporalCursor (-7))
  VtyEvent (V.EvKey V.KDown []) -> modify (moveTemporalCursor 7)
  VtyEvent (V.EvKey (V.KChar 'h') []) -> modify (moveTemporalCursor (-1))
  VtyEvent (V.EvKey (V.KChar 'H') []) -> modify (moveTemporalCursor (-1))
  VtyEvent (V.EvKey (V.KChar 'l') []) -> modify (moveTemporalCursor 1)
  VtyEvent (V.EvKey (V.KChar 'L') []) -> modify (moveTemporalCursor 1)
  VtyEvent (V.EvKey (V.KChar 'k') []) -> modify (moveTemporalCursor (-7))
  VtyEvent (V.EvKey (V.KChar 'K') []) -> modify (moveTemporalCursor (-7))
  VtyEvent (V.EvKey (V.KChar 'j') []) -> modify (moveTemporalCursor 7)
  VtyEvent (V.EvKey (V.KChar 'J') []) -> modify (moveTemporalCursor 7)
  VtyEvent (V.EvKey (V.KChar 't') []) -> modify selectToday
  VtyEvent (V.EvKey (V.KChar 'T') []) -> modify selectToday
  _ -> pure ()

handleSectionEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleSectionEvent event = case event of
  VtyEvent (V.EvKey V.KUp []) -> modify (moveSection (-1))
  VtyEvent (V.EvKey V.KDown []) -> modify (moveSection 1)
  VtyEvent (V.EvKey (V.KChar 'k') []) -> modify (moveSection (-1))
  VtyEvent (V.EvKey (V.KChar 'K') []) -> modify (moveSection (-1))
  VtyEvent (V.EvKey (V.KChar 'j') []) -> modify (moveSection 1)
  VtyEvent (V.EvKey (V.KChar 'J') []) -> modify (moveSection 1)
  VtyEvent (V.EvKey V.KRight []) -> enterSurface
  VtyEvent (V.EvKey V.KEnter []) -> enterSurface
  _ -> pure ()
  where
    enterSurface = modify (\state -> state { homeFocus = SurfaceFocus })

handleSurfaceEvent :: BrickEvent Name () -> EventM Name HomeState ()
handleSurfaceEvent event = case event of
  VtyEvent (V.EvKey V.KLeft []) ->
    modify (\state -> state { homeFocus = SectionFocus })
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
        , (focusAttr, V.withStyle V.defAttr V.bold)
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
        , homeTemporalCursorDay = observedOn
        , homeFocus = CalendarFocus
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
