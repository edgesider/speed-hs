{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Conduit as C
import Control.Applicative (liftA)
import Control.Monad (unless, when)
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
    lastProgressTime :: UTCTime
  }
  deriving (Show)

main :: IO ()
main = do
  let totalSize = 100

  r <- randomRIO (0.0, 1.0) :: IO Double
  req' <- parseRequest $ "https://test.ustc.edu.cn/backend/garbage.php?r=" ++ show r ++ "&ckSize=" ++ show totalSize
  let req = setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  now <- getCurrentTime
  stateRef <-
    newIORef
      AppState
        { totalSize = 1024 * 1024 * totalSize,
          receivedSize = 0,
          startTime = now,
          lastReceivedTime = UTCTime (ModifiedJulianDay 0) 0,
          lastProgressTime = now
        }
  httpSink req (const $ loop stateRef)
  finalState <- readIORef stateRef

  let diff = lastReceivedTime finalState `diffUTCTime` startTime finalState
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  putStrLn $ "总下载大小: " ++ formatSize (receivedSize finalState)
  putStrLn $ "测试时间: " ++ show (realToFrac diff :: Double) ++ " 秒"
  putStrLn $ "下载速度: " ++ formatSpeed ((fromIntegral (receivedSize finalState) :: Double) / realToFrac diff)
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

loop :: IORef AppState -> ConduitM ByteString Void IO ()
loop stateRef = do
  mx <- await
  case mx of
    Nothing -> finish
    Just x -> do
      state <- liftIO $ do
        now <- getCurrentTime
        state <- readIORef stateRef
        writeIORef stateRef $ state {receivedSize = receivedSize state + BS.length x, lastReceivedTime = now}
        progress state
      if receivedSize state >= totalSize state
        then finish
        else loop stateRef
  where
    finish = liftIO $ putStr "\r"
    progress state = do
      state <- readIORef stateRef
      when (lastReceivedTime state `diffUTCTime` lastProgressTime state > 0.5) $ do
        liftIO $ do
          putStr $ "\r" ++ formatSize (receivedSize state) ++ " / " ++ formatSize (totalSize state) ++ Prelude.replicate 5 ' '
          hFlush stdout
          writeIORef stateRef $ state {lastProgressTime = lastReceivedTime state}
      readIORef stateRef

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
