{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Codec.Binary.UTF8.Generic (fromString)
import Conduit as C
import Control.Applicative (liftA)
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import qualified Control.Concurrent.MVar as MVar
import Control.Monad (forM, forM_, forever, unless, when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString as CL
import Data.Conduit
import qualified Data.Conduit.List as CL
import Data.HashMap.Strict (keys)
import Data.IORef (IORef, modifyIORef, modifyIORef', newIORef, readIORef, writeIORef)
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
    transferredSize :: Int,
    startTime :: UTCTime,
    lastTransferTime :: UTCTime
  }
  deriving (Show)

data TestResult = TestResult
  { transferred :: Int,
    duration :: Double,
    speed :: Double
  }
  deriving (Show)

main :: IO ()
main = do
  test True
  test False
  where
    numThreads = 8 -- 并发线程数
    totalSize = 1024 * 1024 * 100 -- 传输大小
    test isDownload = do
      progressMVar <- newMVar Map.empty
      -- 创建多个测试线程
      let run = if isDownload then runDownload else runUpload
      forM_ [1 .. numThreads] $ \tid -> do
        forkIO $ run tid (totalSize `div` numThreads) progressMVar

      allDone <- newEmptyMVar
      forkIO $ showProgress progressMVar allDone

      -- 等待所有测试完成并显示结果
      readMVar allDone
      -- TODO 应该查看所有线程并行阶段的速度，而不是等待所有线程完成，或者是根据所有线程传输的总量决定是否终止
      showResult isDownload progressMVar

runUpload :: Int -> Int -> MVar (Map.Map Int ThreadState) -> IO ()
runUpload tid bytes progressMVar = do
  r <- randomRIO (0.0, 1.0) :: IO Double
  req' <- parseRequest $ "http://test.ustc.edu.cn/backend/empty.php?r=" ++ show r
  let req =
        setRequestMethod "post"
          $ setRequestHeader "Cookie" ["ustc=1"]
          $ setRequestHeader "Content-Type" ["application/x-www-form-urlencoded"]
          $ setRequestBodySource
            (fromIntegral bytes)
            (byteChunks bytes .| monitorSource tid progressMVar)
          $ req'
  state <- initThreadState bytes tid
  modifyMVar_ progressMVar $ \m -> return $ Map.insert tid state m

  httpLBS req
  return ()

monitorSource :: Int -> MVar (Map.Map Int ThreadState) -> ConduitT BS.ByteString BS.ByteString IO ()
monitorSource tid progressMVar = do
  sendingSize <- liftIO $ newIORef 0
  CL.mapM $ \chunk -> do
    let done = BS.length chunk == 0 -- 最后一块大小为0,表示结束
    liftIO do
      -- 此时，上一个数据块被发出去了
      sent <- readIORef sendingSize
      now <- getCurrentTime
      state <- getThreadState tid progressMVar
      updateThreadState
        tid
        progressMVar
        state
          { transferredSize = sent,
            lastTransferTime = now,
            finished = done
          }

      -- chunk 是将要被发送的数据块，还没被发出去，更新下发送之后的大小，以便下次使用
      modifyIORef' sendingSize \s -> s + BS.length chunk
    return chunk

runDownload :: Int -> Int -> MVar (Map.Map Int ThreadState) -> IO ()
runDownload tid bytes progressMVar = do
  r <- randomRIO (0.0, 1.0) :: IO Double
  let blockSize = ceiling $ (fromIntegral bytes :: Double) / 1024 / 1024
  req' <-
    parseRequest $
      "https://test.ustc.edu.cn/backend/garbage.php?r="
        ++ show r
        ++ "&ckSize="
        ++ show blockSize

  let req = setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  state <- initThreadState bytes tid
  modifyMVar_ progressMVar $ \m -> return $ Map.insert tid state m

  httpSink req $ const $ monitorSink tid progressMVar

monitorSink :: Int -> MVar (Map.Map Int ThreadState) -> ConduitM BS.ByteString Void IO ()
monitorSink tid progressMVar =
  do
    CL.mapM $ \chunk -> do
      now <- getCurrentTime
      state <- getThreadState tid progressMVar
      let recv = transferredSize state + BS.length chunk
      let done = recv >= totalSize state
      updateThreadState
        tid
        progressMVar
        state
          { transferredSize = recv,
            lastTransferTime = now,
            finished = done
          }
      return $ not done
    .| takeWhileC id
    .| CL.mapM_ \_ -> return ()

byteChunks :: Int -> ConduitT () BS.ByteString IO ()
byteChunks = loop
  where
    chunkSize = 1024 * 1024
    loop remain
      | remain <= 0 = do
          yield $ BS.pack [] -- 多生成一个空块，以便下游能感知到最后一块发送完毕
      | otherwise = do
          let currentChunk = BS.replicate (min remain chunkSize) 30
          yield currentChunk
          loop (remain - chunkSize)

initThreadState :: Int -> Int -> IO ThreadState
initThreadState size tid = do
  now <- getCurrentTime
  return
    ThreadState
      { totalSize = size,
        transferredSize = 0,
        startTime = now,
        lastTransferTime = UTCTime (ModifiedJulianDay 0) 0,
        threadId = tid,
        finished = False
      }

getThreadState :: Int -> MVar (Map.Map Int ThreadState) -> IO ThreadState
getThreadState selfTid progressMVar = do
  map <- readMVar progressMVar
  case Map.lookup selfTid map of
    Just s -> return s
    Nothing -> error "thread state not found"

updateThreadState :: Int -> MVar (Map.Map Int ThreadState) -> ThreadState -> IO ()
updateThreadState selfTid progressMVar newState = do
  modifyMVar_ progressMVar $
    \m -> return $ Map.insert selfTid newState m

showProgress :: MVar (Map.Map Int ThreadState) -> MVar Bool -> IO ()
showProgress progressMVar allDoneMVar = do
  loop'
  where
    loop' = do
      threadDelay 500000 -- 每0.5秒更新一次
      states <- readMVar progressMVar
      let sumRecv = Map.foldl (\acc state -> acc + transferredSize state) 0 states
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

calcResult :: ThreadState -> TestResult
calcResult state =
  TestResult
    { transferred = transferred,
      duration = duration,
      speed = (fromIntegral transferred :: Double) / duration
    }
  where
    duration = realToFrac $ lastTransferTime state `diffUTCTime` startTime state
    transferred = transferredSize state

showResult :: Bool -> MVar (Map.Map Int ThreadState) -> IO ()
showResult isDownload progressMVar = do
  progress <- readMVar progressMVar
  -- 计算总的下载数据和总时间
  let results = map (calcResult . snd) (Map.toList progress)
  let totalBytes = sum $ map transferred results
      avgDuration = sum (map duration results) / fromIntegral (Map.size progress)
      totalSpeed = sum $ map speed results
  putStr "\r"
  putStrLn $
    (if isDownload then "⬇️  " else "⬆️  ")
      ++ formatSpeed totalSpeed False
      ++ " ("
      ++ formatSpeed totalSpeed True
      ++ ") ⚡"

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
