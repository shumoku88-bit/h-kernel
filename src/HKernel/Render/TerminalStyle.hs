{-# LANGUAGE OverloadedStrings #-}

-- | Shared pure rendering primitives used by the terminal reports.
module HKernel.Render.TerminalStyle
  ( Alignment(..)
  , Cell
  , plainCell
  , styledCell
  , plainBalanceCell
  , greenBalanceCell
  , redBalanceCell
  , signedBalanceCell
  , signedAmountCell
  , plainBalanceCellWith
  , greenBalanceCellWith
  , redBalanceCellWith
  , signedBalanceCellWith
  , signedAmountCellWith
  , terminalHeader
  , terminalHeaderWith
  , terminalMeta
  , terminalBold
  , terminalBoldThen
  , terminalDim
  , terminalYellow
  , terminalSectionWith
  , terminalGreen
  , terminalRed
  , terminalPositiveAmountWith
  , terminalNegativeAmountWith
  , terminalRedWith
  , renderTerminalTable
  , renderBalancePlain
  , renderBalanceGreen
  , renderBalanceRed
  , renderBalanceSigned
  , renderAmountSigned
  , renderBalancePlainWith
  , renderBalanceGreenWith
  , renderBalanceRedWith
  , renderBalanceSignedWith
  , renderAmountSignedWith
  , displayWidth
  , padDisplayWidth
  , wrapDisplayWidth
  ) where

import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import HKernel.Money
import HKernel.Report.Presentation
  ( NegativeStyle(..)
  , PresentationColor(..)
  , PresentationConfig(..)
  , defaultPresentationConfig
  )

clrReset, clrBold, clrRed, clrGreen, clrYellow, clrDim :: Text
clrReset = "\ESC[0m"
clrBold = "\ESC[1m"
clrRed = "\ESC[31m"
clrGreen = "\ESC[32m"
clrYellow = "\ESC[33m"
clrDim = "\ESC[2m"

presentationColorCode :: PresentationColor -> Text
presentationColorCode color = case color of
  RedColor       -> "31"
  BrightRedColor -> "91"
  GreenColor     -> "32"
  YellowColor    -> "33"
  BlueColor      -> "34"
  MagentaColor   -> "35"
  CyanColor      -> "36"
  WhiteColor     -> "37"

presentationColorControl :: PresentationColor -> Text
presentationColorControl color = "\ESC[" <> presentationColorCode color <> "m"

presentationBoldColorControl :: PresentationColor -> Text
presentationBoldColorControl color =
  "\ESC[1;" <> presentationColorCode color <> "m"

terminalHeader :: Text -> Text
terminalHeader = terminalHeaderWith defaultPresentationConfig

terminalHeaderWith :: PresentationConfig -> Text -> Text
terminalHeaderWith config title =
  wrap (presentationBoldColorControl (presentationHeadingColor config))
    ("== " <> title <> " ==")

terminalMeta :: Text -> Text
terminalMeta = terminalDim

terminalBold :: Text -> Text
terminalBold = wrap clrBold

-- | Start a bold prefix and continue directly into a complete styled value.
-- The styled value supplies the reset, used by the status-line sequence.
terminalBoldThen :: Text -> Text -> Text
terminalBoldThen prefix styled = clrBold <> prefix <> styled

terminalDim :: Text -> Text
terminalDim = wrap clrDim

terminalYellow :: Text -> Text
terminalYellow = wrap clrYellow

terminalSectionWith :: PresentationConfig -> Text -> Text
terminalSectionWith config =
  wrap (presentationColorControl (presentationSectionColor config))

-- | Fixed success status tone. Amount-positive presentation uses
-- 'terminalPositiveAmountWith' instead.
terminalGreen :: Text -> Text
terminalGreen = wrap clrGreen

-- | Fixed failure/warning status tone. Amount-negative presentation uses
-- 'terminalNegativeAmountWith' instead.
terminalRed :: Text -> Text
terminalRed = wrap clrRed

terminalPositiveAmountWith :: PresentationConfig -> Text -> Text
terminalPositiveAmountWith config =
  wrap (presentationColorControl (presentationPositiveAmountColor config))

terminalNegativeAmountWith :: PresentationConfig -> Text -> Text
terminalNegativeAmountWith config =
  wrap (presentationColorControl (presentationNegativeAmountColor config))

terminalRedWith :: PresentationColor -> Text -> Text
terminalRedWith color = wrap (presentationColorControl color)

wrap :: Text -> Text -> Text
wrap code value = code <> value <> clrReset

data Alignment = AlignLeft | AlignRight

-- | Keep width-bearing text separate from its ANSI-decorated publication.
data Cell = Cell
  { cellPlain  :: Text
  , cellStyled :: Text
  }

plainCell :: Text -> Cell
plainCell value = Cell value value

styledCell :: (Text -> Text) -> Text -> Cell
styledCell style value = Cell value (style value)

data BalanceTone
  = PlainTone
  | PositiveTone PresentationColor
  | NegativeTone PresentationColor
  | SignedTone PresentationColor PresentationColor

plainBalanceCell :: Balance -> Cell
plainBalanceCell = plainBalanceCellWith defaultPresentationConfig

greenBalanceCell :: Balance -> Cell
greenBalanceCell = greenBalanceCellWith defaultPresentationConfig

redBalanceCell :: Balance -> Cell
redBalanceCell = redBalanceCellWith defaultPresentationConfig

signedBalanceCell :: Balance -> Cell
signedBalanceCell = signedBalanceCellWith defaultPresentationConfig

signedAmountCell :: Amount -> Cell
signedAmountCell = signedAmountCellWith defaultPresentationConfig

plainBalanceCellWith :: PresentationConfig -> Balance -> Cell
plainBalanceCellWith config = balanceCell config PlainTone

greenBalanceCellWith :: PresentationConfig -> Balance -> Cell
greenBalanceCellWith config =
  balanceCell config (PositiveTone (presentationPositiveAmountColor config))

redBalanceCellWith :: PresentationConfig -> Balance -> Cell
redBalanceCellWith config =
  balanceCell config (NegativeTone (presentationNegativeAmountColor config))

signedBalanceCellWith :: PresentationConfig -> Balance -> Cell
signedBalanceCellWith config =
  balanceCell config
    (SignedTone
      (presentationPositiveAmountColor config)
      (presentationNegativeAmountColor config))

signedAmountCellWith :: PresentationConfig -> Amount -> Cell
signedAmountCellWith config amount =
  let plain = renderAmountPlainWith config amount
  in Cell plain
      (styleQuantity
        (presentationPositiveAmountColor config)
        (presentationNegativeAmountColor config)
        (amountQuantity amount)
        plain)

renderBalancePlain :: Balance -> Text
renderBalancePlain = cellStyled . plainBalanceCell

renderBalanceGreen :: Balance -> Text
renderBalanceGreen = cellStyled . greenBalanceCell

renderBalanceRed :: Balance -> Text
renderBalanceRed = cellStyled . redBalanceCell

renderBalanceSigned :: Balance -> Text
renderBalanceSigned = cellStyled . signedBalanceCell

renderAmountSigned :: Amount -> Text
renderAmountSigned = cellStyled . signedAmountCell

renderBalancePlainWith :: PresentationConfig -> Balance -> Text
renderBalancePlainWith config = cellStyled . plainBalanceCellWith config

renderBalanceGreenWith :: PresentationConfig -> Balance -> Text
renderBalanceGreenWith config = cellStyled . greenBalanceCellWith config

renderBalanceRedWith :: PresentationConfig -> Balance -> Text
renderBalanceRedWith config = cellStyled . redBalanceCellWith config

renderBalanceSignedWith :: PresentationConfig -> Balance -> Text
renderBalanceSignedWith config = cellStyled . signedBalanceCellWith config

renderAmountSignedWith :: PresentationConfig -> Amount -> Text
renderAmountSignedWith config = cellStyled . signedAmountCellWith config

balanceCell :: PresentationConfig -> BalanceTone -> Balance -> Cell
balanceCell config tone balance = case balanceEntries balance of
  [] -> Cell "0" (styleZero tone)
  entries -> Cell plain (styleBalance config tone entries plain)
    where
      plain = T.intercalate ", "
        [ renderEntryPlain config commodity quantity
        | (commodity, quantity) <- entries
        ]

styleZero :: BalanceTone -> Text
styleZero tone = case tone of
  PlainTone -> "0"
  PositiveTone color -> terminalRedWith color "0"
  NegativeTone color -> terminalRedWith color "0"
  SignedTone _ _ -> terminalDim "0"

styleBalance
  :: PresentationConfig
  -> BalanceTone
  -> [(Commodity, Quantity)]
  -> Text
  -> Text
styleBalance config tone entries plain = case tone of
  PlainTone -> plain
  PositiveTone color -> terminalRedWith color plain
  NegativeTone color -> terminalRedWith color plain
  SignedTone positiveColor negativeColor
    | all ((> zeroQuantity) . snd) entries -> terminalRedWith positiveColor plain
    | all ((< zeroQuantity) . snd) entries -> terminalRedWith negativeColor plain
    | all ((== zeroQuantity) . snd) entries -> terminalDim plain
    | otherwise -> T.intercalate ", "
        [ styleQuantity positiveColor negativeColor quantity
            (renderEntryPlain config commodity quantity)
        | (commodity, quantity) <- entries
        ]

renderEntryPlain :: PresentationConfig -> Commodity -> Quantity -> Text
renderEntryPlain config commodity quantity
  | quantity < zeroQuantity = case presentationNegativeStyle config of
      AccountingParentheses -> "(" <> unsigned <> ")"
      LeadingMinus -> "-" <> unsigned
  | otherwise = unsigned
  where
    unsigned = formatQuantityMagnitude quantity
      <> " " <> commodityCode commodity

renderAmountPlainWith :: PresentationConfig -> Amount -> Text
renderAmountPlainWith config amount =
  renderEntryPlain config
    (amountCommodity amount) (amountQuantity amount)

styleQuantity
  :: PresentationColor
  -> PresentationColor
  -> Quantity
  -> Text
  -> Text
styleQuantity positiveColor negativeColor quantity value
  | quantity < zeroQuantity = terminalRedWith negativeColor value
  | quantity > zeroQuantity = terminalRedWith positiveColor value
  | otherwise = terminalDim value

formatQuantityMagnitude :: Quantity -> Text
formatQuantityMagnitude quantity = groupedWhole <> fraction
  where
    magnitude
      | quantity < zeroQuantity = negateQuantity quantity
      | otherwise = quantity
    (whole, fraction) = T.breakOn "." (renderQuantity magnitude)
    groupedWhole = groupThousands whole

groupThousands :: Text -> Text
groupThousands digits = T.reverse
  (T.intercalate "," (chunksOfThree (T.reverse digits)))

chunksOfThree :: Text -> [Text]
chunksOfThree text
  | T.null text = []
  | otherwise = T.take 3 text : chunksOfThree (T.drop 3 text)

renderTerminalTable
  :: [(Text, Alignment)]
  -> [[Cell]]
  -> Maybe [Cell]
  -> Text
renderTerminalTable columns rows summary =
  T.unlines (header : rule : renderedRows ++ renderedSummary)
  where
    normalizedRows = map normalize rows
    normalizedSummary = fmap normalize summary
    allRows = normalizedRows ++ maybe [] pure normalizedSummary
    widths =
      [ maximum
          (displayWidth title :
            [ displayWidth (cellPlain cell)
            | row <- allRows
            , cell <- takeOne index row
            ])
      | (index, (title, _)) <- zip [0..] columns
      ]
    headerPlain = renderPlainRow widths (map (plainCell . fst) columns)
    header = terminalBold headerPlain
    rule = terminalDim (T.replicate (displayWidth headerPlain) "-")
    renderedRows = map (renderStyledRow widths) normalizedRows
    renderedSummary = case normalizedSummary of
      Nothing -> []
      Just row -> [rule, renderStyledRow widths row]

    normalize cells = take (length columns) (cells ++ repeat (plainCell ""))

    renderPlainRow columnWidths cells = T.stripEnd (T.intercalate " | "
      [ pad alignment width (cellPlain cell)
      | ((_, alignment), width, cell) <- zip3 columns columnWidths cells
      ])

    renderStyledRow columnWidths cells = T.stripEnd (T.intercalate " | "
      [ padStyled alignment width cell
      | ((_, alignment), width, cell) <- zip3 columns columnWidths cells
      ])

    takeOne index row = take 1 (drop index row)

pad :: Alignment -> Int -> Text -> Text
pad alignment width value = case alignment of
  AlignLeft  -> value <> spaces
  AlignRight -> spaces <> value
  where
    spaces = T.replicate (max 0 (width - displayWidth value)) " "

padStyled :: Alignment -> Int -> Cell -> Text
padStyled alignment width cell = case alignment of
  AlignLeft  -> cellStyled cell <> spaces
  AlignRight -> spaces <> cellStyled cell
  where
    spaces = T.replicate (max 0 (width - displayWidth (cellPlain cell))) " "

displayWidth :: Text -> Int
displayWidth = T.foldl' (\width character -> width + characterWidth character) 0

padDisplayWidth :: Int -> Text -> Text
padDisplayWidth width value =
  value <> T.replicate (max 0 (width - displayWidth value)) " "

-- | Greedily wrap text without splitting a terminal display cell. This treats
-- CJK characters with the same width policy as terminal table alignment.
wrapDisplayWidth :: Int -> Text -> [Text]
wrapDisplayWidth width value
  | T.null value = [""]
  | width <= 0 = [value]
  | otherwise = reverse (finish (T.foldl' addCharacter ([], "", 0) value))
  where
    addCharacter (lines', current, currentWidth) character
      | currentWidth + characterWidth character > width =
          (current : lines', T.singleton character, characterWidth character)
      | otherwise =
          (lines', T.snoc current character, currentWidth + characterWidth character)
    finish (lines', current, _) = current : lines'

characterWidth :: Char -> Int
characterWidth character
  | code >= 0x1100 &&
      ( code <= 0x115f
        || code == 0x2329 || code == 0x232a
        || (code >= 0x2e80 && code <= 0xa4cf && code /= 0x303f)
        || (code >= 0xac00 && code <= 0xd7a3)
        || (code >= 0xf900 && code <= 0xfaff)
        || (code >= 0xfe10 && code <= 0xfe19)
        || (code >= 0xfe30 && code <= 0xfe6f)
        || (code >= 0xff00 && code <= 0xff60)
        || (code >= 0xffe0 && code <= 0xffe6)
      ) = 2
  | otherwise = 1
  where
    code = ord character
