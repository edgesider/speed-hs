module Main (main) where

import Codec.Binary.UTF8.Generic (fromString)
import Conduit as C
import Control.Applicative (liftA)
import Control.Concurrent (forkFinally, forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar)
import Control.Exception (Exception (fromException), SomeException (SomeException))
import Control.Monad (forM, forM_, forever, unless, void, when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
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
import Summary (isSummaryDone, newSummary, updateSummary)
import qualified Summary
import System.IO (stdout)
import Text.Printf (printf)
import Utils (byteChunks, formatSize, formatSpeed, randomStr)

data Direction = Upload | Download

main :: IO ()
main = do
  test Download
  threadDelay 1000000
  test Upload
  where
    targetSeconds = 2
    numThreads = 8
    maxSize = 1024 * 1024 * 10000 -- TODO remove
    test (direction :: Direction) = do
      now <- getCurrentTime
      summaryMVar <- newMVar $ newSummary now targetSeconds
      -- 创建多个测试线程
      let run = case direction of
            Download -> runDownload
            Upload -> runUpload
      forM_ [1 .. numThreads] $ \tid -> do
        forkFinally (run tid maxSize summaryMVar) $ \case
          Left e -> case fromException e :: Maybe HttpException of -- TODO 异常处理（断链、超时等）
          -- 上传时可能会出现传输大小不一致的错误，忽略
            Just (HttpExceptionRequest _ (WrongRequestBodyStreamSize _ _)) -> return ()
            _ -> putStrLn $ "Error: " ++ show e
          Right _ -> return ()

      allDone <- newEmptyMVar
      forkIO $ showProgress direction allDone summaryMVar

      -- 等待所有测试完成并显示结果
      readMVar allDone
      showResult direction summaryMVar

runUpload :: Int -> Int -> MVar Summary.Summary -> IO ()
runUpload tid bytes summaryMVar = do
  r <- randomStr
  req' <- parseRequest $ "http://test.ustc.edu.cn/backend/empty.php?r=" ++ r

  let req =
        setRequestMethod "post"
          $ setRequestHeader "Cookie" ["ustc=1"]
          $ setRequestHeader "Content-Type" ["application/x-www-form-urlencoded"]
          $ setRequestBodySource
            (fromIntegral bytes)
            (byteChunks bytes .| monitorSource summaryMVar)
          $ req'
  httpLBS req
  return ()

monitorSource :: MVar Summary.Summary -> ConduitT BS.ByteString BS.ByteString IO ()
monitorSource summaryMVar =
  do
    lastChunkSizeRef <- liftIO $ newIORef 0
    CL.mapM $ \chunk -> do
      liftIO do
        -- 此时，上一个数据块被发出去了，获取它的大小
        lastChunkSize <- readIORef lastChunkSizeRef
        -- chunk 是将要被发送的数据块，保存一下
        writeIORef lastChunkSizeRef $ BS.length chunk

        done <- updateSummary lastChunkSize summaryMVar
        return if done then BS.pack [] else chunk
    .| takeWhileC \c -> BS.length c > 0

runDownload :: Int -> Int -> MVar Summary.Summary -> IO ()
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

monitorSink :: Int -> MVar Summary.Summary -> ConduitM BS.ByteString Void IO ()
monitorSink tid summaryMVar =
  do
    CL.mapM $ \chunk -> do
      done <- updateSummary (BS.length chunk) summaryMVar
      return $ not done
    .| takeWhileC id
    .| CL.mapM_ \_ -> return ()

getLogPrefix :: Direction -> String
getLogPrefix direction = case direction of
  Download -> "⬇️  "
  Upload -> "⬆️  "

showProgress :: Direction -> MVar Bool -> MVar Summary.Summary -> IO ()
showProgress direction allDoneMVar summaryMVar = do
  loop'
  where
    loop' = do
      threadDelay 200000 -- 每0.2秒更新一次
      summary <- readMVar summaryMVar
      let isDone = isSummaryDone summary
      let sumRecv = Summary.transferredBytes summary
      putStr $
        "\r"
          ++ getLogPrefix direction
          ++ formatSize sumRecv
          ++ Prelude.replicate 5 ' '
      hFlush stdout
      if not isDone
        then loop'
        else putMVar allDoneMVar True

showResult :: Direction -> MVar Summary.Summary -> IO ()
showResult direction summaryMVar = do
  summary <- readMVar summaryMVar
  -- 计算总的下载数据和总时间
  let total = Summary.transferredBytes summary
      duration = realToFrac (Summary.lastTransferTime summary `diffUTCTime` Summary.startTime summary)
      speed = (fromIntegral total :: Double) / duration
  putStrLn $
    "\r"
      ++ getLogPrefix direction
      ++ formatSpeed speed False
      ++ " ("
      ++ formatSpeed speed True
      ++ ", "
      ++ (formatSize total ++ " in " ++ printf "%.2f" duration ++ " seconds")
      ++ ") ⚡"
