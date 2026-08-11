module Test.Support
  ( assertEqual
  , mustRight
  , mustJust
  ) where

import System.Exit (exitFailure)

assertEqual :: (Eq value, Show value) => String -> value -> value -> IO ()
assertEqual label expected actual
  | expected == actual = putStrLn ("  [PASS] " ++ label)
  | otherwise = do
      putStrLn ("  [FAIL] " ++ label)
      putStrLn ("    expected: " ++ show expected)
      putStrLn ("    but got:  " ++ show actual)
      exitFailure

mustRight :: Show error => Either error value -> value
mustRight (Right value) = value
mustRight (Left err) = error ("invalid test fixture: " ++ show err)

mustJust :: Maybe value -> value
mustJust (Just value) = value
mustJust Nothing = error "invalid test fixture: expected Just"
