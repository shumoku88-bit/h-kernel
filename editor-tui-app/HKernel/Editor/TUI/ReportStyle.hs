{-# LANGUAGE OverloadedStrings #-}

-- | Brick-native publication of the ANSI styling emitted by report renderers.
--
-- Report renderers remain terminal-presentation owners. This adapter consumes
-- their SGR controls before Brick sees any text, preserving terminal colours
-- and emphasis without letting escape sequences participate in Brick layout.
module HKernel.Editor.TUI.ReportStyle
  ( renderTerminalReport
  ) where

import Brick (Widget, hBox, modifyDefAttr, str, txt, vBox)
import Data.List (mapAccumL)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Graphics.Vty as V
import Text.Read (readMaybe)

data SgrStyle = SgrStyle
  { sgrForeground :: Maybe V.Color
  , sgrBold :: Bool
  , sgrDim :: Bool
  }

data StyledChunk = StyledChunk SgrStyle Text

defaultSgrStyle :: SgrStyle
defaultSgrStyle = SgrStyle
  { sgrForeground = Nothing
  , sgrBold = False
  , sgrDim = False
  }

-- | Convert ANSI SGR report text into Brick widgets without exposing control
-- sequences to Brick's text-width calculation.
renderTerminalReport :: Text -> Widget n
renderTerminalReport source = vBox (map renderLine styledLines)
  where
    (_, styledLines) = mapAccumL parseLine defaultSgrStyle (T.splitOn "\n" source)

renderLine :: [StyledChunk] -> Widget n
renderLine [] = str " "
renderLine chunks = hBox (map renderChunk chunks)

renderChunk :: StyledChunk -> Widget n
renderChunk (StyledChunk style value) =
  modifyDefAttr (applyStyle style) (txt value)

applyStyle :: SgrStyle -> V.Attr -> V.Attr
applyStyle style base = applyDim (applyBold (applyForeground base))
  where
    applyForeground attr = case sgrForeground style of
      Nothing -> attr
      Just color -> V.withForeColor attr color
    applyBold attr
      | sgrBold style = V.withStyle attr V.bold
      | otherwise = attr
    applyDim attr
      | sgrDim style = V.withStyle attr V.dim
      | otherwise = attr

parseLine :: SgrStyle -> Text -> (SgrStyle, [StyledChunk])
parseLine initialStyle = go initialStyle []
  where
    go style chunks remaining
      | T.null remaining = (style, reverse chunks)
      | otherwise =
          let (plain, control) = T.breakOn "\ESC[" remaining
              chunks' = addChunk style plain chunks
          in if T.null control
              then (style, reverse chunks')
              else
                let afterPrefix = T.drop 2 control
                    (parameters, suffix) = T.span isSgrParameter afterPrefix
                in case T.uncons suffix of
                    Just ('m', afterSgr) ->
                      go (applySgr parameters style) chunks' afterSgr
                    _ ->
                      -- Drop an unexpected ESC prefix rather than allowing a
                      -- raw terminal control into Brick's layout input.
                      go style chunks' afterPrefix

    addChunk _ value chunks | T.null value = chunks
    addChunk style value chunks = StyledChunk style value : chunks

    isSgrParameter character =
      character == ';' || (character >= '0' && character <= '9')

applySgr :: Text -> SgrStyle -> SgrStyle
applySgr parameters = foldl (flip applyCode) <*> parsedCodes
  where
    parsedCodes
      | T.null parameters = [0]
      | otherwise = foldr collect [] (T.splitOn ";" parameters)
    collect token codes = case parseCode token of
      Nothing -> codes
      Just code -> code : codes
    parseCode token
      | T.null token = Just 0
      | otherwise = readMaybe (T.unpack token)

applyCode :: Int -> SgrStyle -> SgrStyle
applyCode code style = case code of
  0 -> defaultSgrStyle
  1 -> style { sgrBold = True }
  2 -> style { sgrDim = True }
  22 -> style { sgrBold = False, sgrDim = False }
  30 -> withColor V.black
  31 -> withColor V.red
  32 -> withColor V.green
  33 -> withColor V.yellow
  34 -> withColor V.blue
  35 -> withColor V.magenta
  36 -> withColor V.cyan
  37 -> withColor V.white
  39 -> style { sgrForeground = Nothing }
  90 -> withColor V.brightBlack
  91 -> withColor V.brightRed
  92 -> withColor V.brightGreen
  93 -> withColor V.brightYellow
  94 -> withColor V.brightBlue
  95 -> withColor V.brightMagenta
  96 -> withColor V.brightCyan
  97 -> withColor V.brightWhite
  _ -> style
  where
    withColor color = style { sgrForeground = Just color }
