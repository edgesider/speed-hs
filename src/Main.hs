{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Conduit as C
import Control.Applicative (liftA)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import qualified Control.Concurrent.MVar as MVar
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS hiding (putStr)
import qualified Data.ByteString.Lazy.UTF8 as U8
import qualified Data.Conduit.List as CL
import Data.HashMap.Strict (keys)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as TIO
import Data.Time
import GHC.IO.Handle (hFlush)
import GHC.MVar (MVar (MVar))
import Network.HTTP.Simple
import System.IO (stdout)
import System.Random (randomRIO)
import Text.Printf (printf)

data ThreadState = ThreadState
  { threadId :: Int,
    finished :: Bool,
    totalSize :: Int,
    receivedSize :: Int,
    startTime :: UTCTime,
    lastReceivedTime :: UTCTime,
    lastProgressTime :: UTCTime
  }
  deriving (Show)

data TestResult = TestResult
  { downloadSize :: Int,
    testDuration :: Double,
    downloadSpeed :: Double
  }
  deriving (Show)

main :: IO ()
main = do
  let numThreads = 10 -- 并发线程数
      totalSize = 30 -- 每个线程下载的大小
  -- TODO 删除resultsMvar
  resultsMVar <- newMVar Map.empty
  progressMVar <- newMVar Map.empty

  -- 创建多个测试线程
  forM_ [1 .. numThreads] $ \threadId -> do
    forkIO $ runSpeedTest threadId (totalSize `div` numThreads) resultsMVar progressMVar

  allDoneMVar <- newEmptyMVar
  -- 显示进度的线程
  forkIO $ showProgress progressMVar allDoneMVar

  -- 等待所有测试完成并显示结果
  _ <- readMVar allDoneMVar
  -- TODO 应该查看所有线程并行阶段的速度，而不是等待所有线程完成
  showResult resultsMVar numThreads

runSpeedTest :: Int -> Int -> MVar (Map.Map Int TestResult) -> MVar (Map.Map Int ThreadState) -> IO ()
runSpeedTest threadId size resultsMVar progressMVar = do
  r <- randomRIO (0.0, 1.0) :: IO Double
  req' <- parseRequest $ "https://test.ustc.edu.cn/backend/garbage.php?r=" ++ show r ++ "&ckSize=" ++ show size
  let req = setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  now <- getCurrentTime

  -- 更新进度状态
  modifyMVar_ progressMVar $ \m ->
    return $
      Map.insert
        threadId
        ThreadState
          { totalSize = 1024 * 1024 * size,
            receivedSize = 0,
            startTime = now,
            lastReceivedTime = now,
            lastProgressTime = now,
            threadId = threadId,
            finished = False
          }
        m

  httpSink req (const $ loop threadId progressMVar)
  finalState <- getThreadState threadId progressMVar

  let diff = lastReceivedTime finalState `diffUTCTime` startTime finalState
      result =
        TestResult
          { downloadSize = receivedSize finalState,
            testDuration = realToFrac diff,
            downloadSpeed = (fromIntegral (receivedSize finalState) :: Double) / realToFrac diff
          }

  -- 更新结果
  modifyMVar_ resultsMVar $ \m -> return $ Map.insert threadId result m

getThreadState :: Int -> MVar (Map.Map Int ThreadState) -> IO ThreadState
getThreadState selfTid progressMVar = do
  map <- readMVar progressMVar
  case Map.lookup selfTid map of
    Just s -> return s
    Nothing -> error "thread state not found"

updateThreadState :: Int -> ThreadState -> MVar (Map.Map Int ThreadState) -> IO ()
updateThreadState selfTid newState progressMVar = do
  modifyMVar_ progressMVar $
    \m -> return $ Map.insert selfTid newState m

loop :: Int -> MVar (Map.Map Int ThreadState) -> ConduitM BS.ByteString Void IO ()
loop selfTid progressMVar = do
  mx <- await
  case mx of
    Nothing -> return ()
    Just x -> do
      state <- liftIO $ do
        now <- getCurrentTime
        map <- readMVar progressMVar
        state <- getThreadState selfTid progressMVar
        let newState = state {receivedSize = receivedSize state + BS.length x, lastReceivedTime = now}
        updateThreadState selfTid newState progressMVar
        return newState
      if receivedSize state >= totalSize state
        then liftIO $ updateThreadState selfTid (state {finished = True}) progressMVar
        else loop selfTid progressMVar

showProgress :: MVar (Map.Map Int ThreadState) -> MVar Bool -> IO ()
showProgress progressMVar allDoneMVar = do
  loop'
  where
    loop' = do
      threadDelay 500000 -- 每0.5秒更新一次
      states <- readMVar progressMVar
      let sumRecv = Map.foldl (\acc state -> acc + receivedSize state) 0 states
      let targetRecv = Map.foldl (\acc state -> acc + totalSize state) 0 states
      putStr $
        "\r"
          ++ formatSize sumRecv
          ++ " / "
          ++ formatSize targetRecv
          ++ Prelude.replicate 5 ' '
      hFlush stdout
      let runnings = Map.size $ Map.filter (not . finished) states
      if runnings > 0
        then loop'
        else putMVar allDoneMVar True

showResult :: MVar (Map.Map Int TestResult) -> Int -> IO ()
showResult resultsMVar numThreads = do
  results <- readMVar resultsMVar
  -- 计算总的下载数据和总时间
  let totalBytes = sum $ map (downloadSize . snd) $ Map.toList results
      avgDuration = sum $ map (testDuration . snd) $ Map.toList results
      totalSpeed = sum $ map (downloadSpeed . snd) $ Map.toList results

  putStrLn "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  putStrLn "总体统计:"
  putStrLn $ "  总下载大小: " ++ formatSize totalBytes
  putStrLn $ "  平均测试时间: " ++ printf "%.2f" avgDuration ++ " 秒"
  putStrLn $ "  总下载速度: " ++ formatSpeed totalSpeed False ++ " (" ++ formatSpeed totalSpeed True ++ ")"
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

formatSize :: (Show a, Integral a) => a -> [Char]
formatSize bytes
  | bytes < 1024 = show bytes ++ " B"
  | bytes < 1024 * 1024 = printf "%.2f KB" (fromIntegral bytes / 1024 :: Double)
  | bytes < 1024 * 1024 * 1024 = printf "%.2f MB" (fromIntegral bytes / 1024 / 1024 :: Double)
  | otherwise = printf "%.2f GB" (fromIntegral bytes / 1024 / 1024 / 1024 :: Double)

formatSpeed :: Double -> Bool -> String
formatSpeed bytesPerSec inBits
  | speed < 1 = printf "%.2f %s" (speed * 1024) unit1
  | speed < 1024 = printf "%.2f %s" speed unit2
  | otherwise = printf "%.2f %s" (speed / 1024) unit3
  where
    -- 是否转换为比特率
    speed =
      if inBits
        then bytesPerSec * 8 / 1024 / 1024
        else bytesPerSec / 1024 / 1024
    -- 根据是否为比特率选择单位
    unit1 :: String = if inBits then "Kbps" else "KB/s"
    unit2 :: String = if inBits then "Mbps" else "MB/s"
    unit3 :: String = if inBits then "Gbps" else "GB/s"
