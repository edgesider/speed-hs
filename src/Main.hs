{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Codec.Binary.UTF8.Generic (fromString)
import Conduit as C
import Control.Applicative (liftA)
import Control.Concurrent (forkFinally, forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import qualified Control.Concurrent.MVar as MVar
import Control.Exception (Exception (fromException), SomeException (SomeException))
import Control.Monad (forM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Logger (runNoLoggingT)
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString as CL
import Data.Conduit
import qualified Data.Conduit.List as CL
import Data.Data (typeOf)
import Data.HashMap.Strict (keys)
import Data.IORef (IORef, modifyIORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Text.IO as TIO
import Data.Time
import GHC.IO.Handle (hFlush)
import GHC.MVar (MVar (MVar))
import Network.HTTP.Conduit (HttpExceptionContent (WrongRequestBodyStreamSize), RequestBody (RequestBodyStreamChunked))
import Network.HTTP.Simple
import System.IO (stdout)
import System.Random (randomRIO)
import Text.Printf (printf)

data TestResult = TestResult
  { transferred :: Int,
    duration :: Double,
    speed :: Double
  }
  deriving (Show)

data TestSummary = TestSummary
  { transferredBytes :: Int,
    startTime :: UTCTime,
    targetSeconds :: Int,
    lastTransferTime :: UTCTime
  }
  deriving (Show)

main :: IO ()
main = do
  test True
  test False
  where
    targetSeconds = 5
    numThreads = 6
    maxSize = 1024 * 1024 * 10000
    test isDownload = do
      now <- getCurrentTime
      summaryMVar <-
        newMVar
          TestSummary
            { transferredBytes = 0,
              startTime = now,
              targetSeconds = targetSeconds,
              lastTransferTime = UTCTime (ModifiedJulianDay 0) 0
            }
      -- 创建多个测试线程
      let run = if isDownload then runDownload else runUpload
      forM_ [1 .. numThreads] $ \tid -> do
        forkFinally (run tid maxSize summaryMVar) $ \case
          Left e -> case fromException e :: Maybe HttpException of
            -- 上传时可能会出现传输大小不一致的错误，忽略
            Just (HttpExceptionRequest _ (WrongRequestBodyStreamSize _ _)) -> return ()
            _ -> putStrLn $ "Error: " ++ show e
          Right _ -> return ()

      allDone <- newEmptyMVar
      forkIO $ showProgress allDone summaryMVar

      -- 等待所有测试完成并显示结果
      readMVar allDone
      showResult isDownload summaryMVar

runUpload :: Int -> Int -> MVar TestSummary -> IO ()
runUpload =
  doRunUpload

doRunUpload :: Int -> Int -> MVar TestSummary -> IO ()
doRunUpload tid bytes summaryMVar = do
  r <- randomStr
  req' <- parseRequest $ "http://test.ustc.edu.cn/backend/empty.php?r=" ++ r

  -- TODO 拆分成多个小块上传
  let req =
        setRequestMethod "post"
          $ setRequestHeader "Cookie" ["ustc=1"]
          $ setRequestHeader "Content-Type" ["application/x-www-form-urlencoded"]
          $ setRequestBodySource
            (fromIntegral bytes)
            (byteChunks bytes .| monitorSource tid summaryMVar)
          $ req'
  httpLBS req
  return ()

monitorSource :: Int -> MVar TestSummary -> ConduitT BS.ByteString BS.ByteString IO ()
monitorSource tid summaryMVar = do
  lastChunkSizeRef <- liftIO $ newIORef 0
  CL.mapM $ \chunk -> do
    liftIO do
      -- 此时，上一个数据块被发出去了，获取它的大小
      lastChunkSize <- readIORef lastChunkSizeRef
      done <- updateSummary lastChunkSize summaryMVar

      -- chunk 是将要被发送的数据块，还没被发出去
      writeIORef lastChunkSizeRef $ BS.length chunk
      return if done then BS.pack [] else chunk

runDownload :: Int -> Int -> MVar TestSummary -> IO ()
runDownload tid bytes summaryMVar = do
  r <- randomStr
  let blockSize = ceiling $ (fromIntegral bytes :: Double) / 1024 / 1024
  req' <-
    parseRequest $
      "https://test.ustc.edu.cn/backend/garbage.php?r="
        ++ r
        ++ "&ckSize="
        ++ show blockSize

  let req = setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  httpSink req $ const $ monitorSink tid summaryMVar

monitorSink :: Int -> MVar TestSummary -> ConduitM BS.ByteString Void IO ()
monitorSink tid summaryMVar =
  do
    CL.mapM $ \chunk -> do
      done <- updateSummary (BS.length chunk) summaryMVar
      return $ not done
    .| takeWhileC id
    .| CL.mapM_ \_ -> return ()

randomStr :: IO String
randomStr = do
  rand <- randomRIO (0, 1 :: Double)
  return $ printf "%f" rand

byteChunks :: Int -> ConduitT () BS.ByteString IO ()
byteChunks = loop
  where
    chunkSize = 1024 * 64
    loop remain
      | remain <= 0 = do
          yield $ BS.pack [] -- 多生成一个空块，以便下游能感知到最后一块发送完毕
      | otherwise = do
          let currentChunk = BS.replicate (min remain chunkSize) 30
          yield currentChunk
          loop (remain - chunkSize)

showProgress :: MVar Bool -> MVar TestSummary -> IO ()
showProgress allDoneMVar summaryMVar = do
  loop'
  where
    loop' = do
      threadDelay 200000 -- 每0.2秒更新一次
      summary <- readMVar summaryMVar
      let isDone = isSummaryDone summary
      let sumRecv = transferredBytes summary
      putStr $
        "\r"
          ++ formatSize sumRecv
          ++ Prelude.replicate 5 ' '
      hFlush stdout
      if not isDone
        then loop'
        else putMVar allDoneMVar True

showResult :: Bool -> MVar TestSummary -> IO ()
showResult isDownload summaryMVar = do
  summary <- readMVar summaryMVar
  -- 计算总的下载数据和总时间
  let total = transferredBytes summary
      duration = realToFrac (lastTransferTime summary `diffUTCTime` startTime summary)
      speed = (fromIntegral total :: Double) / duration
  putStrLn $ "\n" ++ show total ++ " bytes in " ++ show duration ++ " seconds"
  putStrLn $
    (if isDownload then "⬇️  " else "⬆️  ")
      ++ formatSpeed speed False
      ++ " ("
      ++ formatSpeed speed True
      ++ ") ⚡"

isSummaryDone :: TestSummary -> Bool
isSummaryDone summary =
  lastTransferTime summary `diffUTCTime` startTime summary
    >= secondsToNominalDiffTime (fromIntegral $ targetSeconds summary)

-- 更新已传输的大小，并返回是否已完成
updateSummary :: Int -> MVar TestSummary -> IO Bool
updateSummary transferred summaryMVar = do
  now <- getCurrentTime
  modifyMVar summaryMVar $ \s -> do
    let newSum =
          s
            { transferredBytes = transferred + transferredBytes s,
              lastTransferTime = now
            }
    return (newSum, isSummaryDone newSum)

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
