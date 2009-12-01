module Main where

import Test.QuickCheck (Args, Property, quickCheckWithResult)
import Test.QuickCheck.Test (isSuccess)
import System.Exit (ExitCode(..), exitFailure, exitWith)

import qualified Tests.BlockDevice as BD
import qualified Tests.BlockMap as BM

qcProps :: [(Args, Property)]
qcProps = BD.qcProps True -- "quick" mode for Block Devices
          ++
          BM.qcProps True -- "quick" mode for Block Map

main :: IO ()
main = do
  results <- mapM (uncurry quickCheckWithResult) qcProps
  if all isSuccess results
    then do
      putStrLn "All tests successful."
      exitWith ExitSuccess
    else do 
      putStrLn "One or more tests failed."
      exitFailure
