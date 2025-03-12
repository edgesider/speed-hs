module Summary where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import Data.Time

data Summary = Summary
  { targetSeconds :: Int,
    transferredBytes :: Int,
    startTime :: UTCTime,
    lastTransferTime :: UTCTime
  }
  deriving (Show)

newSummary :: UTCTime -> Int -> Summary
newSummary startTime targetSeconds =
  Summary
    { targetSeconds = targetSeconds,
      transferredBytes = 0,
      startTime = startTime,
      lastTransferTime = UTCTime (ModifiedJulianDay 0) 0
    }

isSummaryDone :: Summary -> Bool
isSummaryDone summary =
  lastTransferTime summary `diffUTCTime` startTime summary
    >= secondsToNominalDiffTime (fromIntegral $ targetSeconds summary)

-- 更新已传输的大小，并返回是否已完成
updateSummary :: Int -> MVar Summary -> IO Bool
updateSummary transferred summaryMVar = do
  now <- getCurrentTime
  modifyMVar summaryMVar $ \s -> do
    let newSum =
          s
            { transferredBytes = transferred + transferredBytes s,
              lastTransferTime = now
            }
    return (newSum, isSummaryDone newSum)