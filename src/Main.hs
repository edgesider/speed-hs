{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Conduit as C
import Control.Applicative (liftA)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Monad (unless, when, forM, forM_)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString as BS hiding (putStr)
import qualified Data.ByteString.Lazy.UTF8 as U8
import qualified Data.Conduit.List as CL
import Data.HashMap.Strict (keys)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as TIO
import Data.Time
import GHC.IO.Handle (hFlush)
import Network.HTTP.Simple
import System.IO (stdout)
import Text.Printf (printf)
import System.Random (randomRIO)

data AppState = AppState
  { totalSize :: Int,
    receivedSize :: Int,
    startTime :: UTCTime,
    lastReceivedTime :: UTCTime,
    lastProgressTime :: UTCTime,
    threadId :: Int
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
  let numThreads = 3  -- 并发线程数
      totalSize = 100  -- 每个线程下载的大小

  resultsMVar <- newMVar Map.empty
  progressMVar <- newMVar Map.empty

  -- 创建多个测试线程
  forM_ [1..numThreads] $ \threadId -> do
    forkIO $ runSpeedTest threadId totalSize resultsMVar progressMVar

  -- 显示进度的线程
  forkIO $ showProgress progressMVar numThreads

  -- 等待所有测试完成并显示结果
  waitAndShowResults resultsMVar numThreads

runSpeedTest :: Int -> Int -> MVar (Map.Map Int TestResult) -> MVar (Map.Map Int AppState) -> IO ()
runSpeedTest threadId size resultsMVar progressMVar = do
  r <- randomRIO (0.0, 1.0) :: IO Double
  req' <- parseRequest $ "https://test.ustc.edu.cn/backend/garbage.php?r=" ++ show r ++ "&ckSize=" ++ show size
  let req = setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  now <- getCurrentTime
  stateRef <-
    newIORef
      AppState
        { totalSize = 1024 * 1024 * size,
          receivedSize = 0,
          startTime = now,
          lastReceivedTime = UTCTime (ModifiedJulianDay 0) 0,
          lastProgressTime = now,
          threadId = threadId
        }

  -- 更新进度状态
  modifyMVar_ progressMVar $ \m -> return $ Map.insert threadId (AppState (1024 * 1024 * size) 0 now now now threadId) m

  httpSink req (const $ loop stateRef progressMVar)
  finalState <- readIORef stateRef

  let diff = lastReceivedTime finalState `diffUTCTime` startTime finalState
      result = TestResult
        { downloadSize = receivedSize finalState,
          testDuration = realToFrac diff,
          downloadSpeed = (fromIntegral (receivedSize finalState) :: Double) / realToFrac diff
        }

  -- 更新结果
  modifyMVar_ resultsMVar $ \m -> return $ Map.insert threadId result m

loop :: IORef AppState -> MVar (Map.Map Int AppState) -> ConduitM ByteString Void IO ()
loop stateRef progressMVar = do
  mx <- await
  case mx of
    Nothing -> finish
    Just x -> do
      state <- liftIO $ do
        now <- getCurrentTime
        state <- readIORef stateRef
        let newState = state {receivedSize = receivedSize state + BS.length x, lastReceivedTime = now}
        writeIORef stateRef newState
        progress newState
        return newState
      if receivedSize state >= totalSize state
        then finish
        else loop stateRef progressMVar
  where
    finish = return ()
    progress state = do
      when (lastReceivedTime state `diffUTCTime` lastProgressTime state > 0.5) $ do
        modifyMVar_ progressMVar $ \m -> return $ Map.insert (threadId state) state m

showProgress :: MVar (Map.Map Int AppState) -> Int -> IO ()
showProgress progressMVar numThreads = do
  let loop' = do
        threadDelay 500000  -- 每0.5秒更新一次
        states <- readMVar progressMVar
        putStr "\r"
        forM_ (Map.toList states) $ \(tid, state) -> do
          putStrLn $ "Thread " ++ show tid ++ ": " ++ 
                     formatSize (receivedSize state) ++ " / " ++ 
                     formatSize (totalSize state)
        when (Map.size states < numThreads) loop'
  loop'

waitAndShowResults :: MVar (Map.Map Int TestResult) -> Int -> IO ()
waitAndShowResults resultsMVar numThreads = do
  let loop' = do
        results <- readMVar resultsMVar
        if Map.size results == numThreads
          then do
            putStrLn "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            putStrLn "测试结果汇总:"
            forM_ (Map.toList results) $ \(tid, result) -> do
              putStrLn $ "Thread " ++ show tid ++ ":"
              putStrLn $ "  总下载大小: " ++ formatSize (downloadSize result)
              putStrLn $ "  测试时间: " ++ show (testDuration result) ++ " 秒"
              putStrLn $ "  下载速度: " ++ formatSpeed (downloadSpeed result)
            putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
          else do
            threadDelay 100000
            loop'
  loop'

formatSize :: (Show a, Integral a) => a -> [Char]
formatSize bytes
  | bytes < 1024 = show bytes ++ " B"
  | bytes < 1024 * 1024 = printf "%.2f KB" (fromIntegral bytes / 1024 :: Double)
  | bytes < 1024 * 1024 * 1024 = printf "%.2f MB" (fromIntegral bytes / 1024 / 1024 :: Double)
  | otherwise = printf "%.2f GB" (fromIntegral bytes / 1024 / 1024 / 1024 :: Double)

formatSpeed :: Double -> String
formatSpeed bytesPerSec
  | speed < 1 = printf "%.2f KB/s" (speed * 1024)
  | speed < 1024 = printf "%.2f MB/s" speed
  | otherwise = printf "%.2f GB/s" (speed / 1024)
  where
    speed = bytesPerSec / 1024 / 1024
