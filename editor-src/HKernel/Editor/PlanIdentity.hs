{-# LANGUAGE OverloadedStrings #-}

-- | Editor-side policy for generated Plan identities.
--
-- The stable Plan domain admits explicit durable identifiers. This module owns
-- only the Editor convention for deriving a description stem and selecting the
-- first available generated identifier. Callers retain the meaning of optional
-- series input and the exact date rendering used to build the generated ID.
module HKernel.Editor.PlanIdentity
  ( descriptionPlanIdStem
  , generateAvailablePlanId
  ) where

import Data.Char (isAsciiLower, isAsciiUpper, toLower)
import Data.Text (Text)
import qualified Data.Text as T

import HKernel.Plan (PlanId, PlanIdError, mkPlanId)

-- | Turn free-form description text into the lexical stem used by generated
-- Plan identities. A description with no ASCII letters or digits falls back to
-- the stable non-empty stem @plan@.
descriptionPlanIdStem :: Text -> Text
descriptionPlanIdStem description =
  let slug = T.intercalate "-"
        (filter (not . T.null) (T.splitOn "-" (T.map mapCharacter description)))
  in if T.null slug then "plan" else slug
  where
    mapCharacter character
      | isAsciiUpper character = toLower character
      | isAsciiLower character = character
      | character >= '0' && character <= '9' = character
      | otherwise = '-'

-- | Build the first unused generated PlanId for one already-decided date text
-- and stem. The caller deliberately owns how those two coordinates were
-- admitted; this owner only owns the generated lexical convention and collision
-- suffix.
generateAvailablePlanId
  :: Text
  -> Text
  -> [PlanId]
  -> Either PlanIdError PlanId
generateAvailablePlanId dateText stem existingIds = go 1
  where
    base = "plan-" <> dateText <> "-" <> stem

    candidateText :: Int -> Text
    candidateText candidateNumber
      | candidateNumber == 1 = base
      | candidateNumber < 10 =
          base <> "-0" <> T.pack (show candidateNumber)
      | otherwise = base <> "-" <> T.pack (show candidateNumber)

    go :: Int -> Either PlanIdError PlanId
    go candidateNumber = do
      candidateId <- mkPlanId (candidateText candidateNumber)
      if candidateId `elem` existingIds
        then go (candidateNumber + 1)
        else Right candidateId
