{-# LANGUAGE OverloadedStrings #-}

-- | Explicit stock origin evidence for one Commodity.
--
-- StockOrigin marks the opening boundary of the Envelope stock world for
-- a Commodity, preserving exact date and memo provenance.
module HKernel.Envelope.StockOrigin
  ( StockOrigin(..)
  , stockOrigin
  ) where

import Data.Text (Text)
import Data.Time.Calendar (Day)
import HKernel.Money (Commodity)

-- | Explicit stock origin evidence for one Commodity.
data StockOrigin = StockOrigin
  { stockOriginDate      :: Day
  , stockOriginCommodity :: Commodity
  , stockOriginNote      :: Text
  } deriving (Eq, Show)

stockOrigin :: Day -> Commodity -> Text -> StockOrigin
stockOrigin = StockOrigin
