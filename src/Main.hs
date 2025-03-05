{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Conduit as C
import Control.Applicative (liftA)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString as BS hiding (putStr)
import qualified Data.ByteString.Lazy.UTF8 as U8
import qualified Data.Conduit.List as CL
import Data.HashMap.Strict (keys)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Text.IO as TIO
import Data.Time
import Network.HTTP.Simple
import System.IO (stdout)
import Text.Printf (printf)
import GHC.IO.Handle (hFlush)

jsonParse :: IO ()
jsonParse = do
  let res = decode $ U8.fromString "{\"你\":\"\"}" :: Maybe Value
  case res of
    Just (Object obj) -> mapM_ (TIO.putStrLn . K.toText) $ KM.keys obj
    Nothing -> print "failed to parse"

main :: IO ()
main = do
  req' <- parseRequest "https://test.ustc.edu.cn/backend/garbage.php?r=0.5811532106165538&ckSize=100"
  let req = setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  startTime <- getCurrentTime

  totalRef <- newIORef 0
  httpSink req $ const $ loop (1024 * 1024 * 100) totalRef startTime
  total <- readIORef totalRef

  endTime <- getCurrentTime
  let diff = diffUTCTime endTime startTime

  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  putStrLn $ "总下载大小: " ++ formatSize total
  putStrLn $ "测试时间: " ++ show (realToFrac diff :: Double) ++ " 秒"
  putStrLn $ "下载速度: " ++ formatSpeed ((fromIntegral total :: Double) / realToFrac diff)
  putStrLn "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

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

loop :: Int -> IORef Int -> UTCTime -> ConduitM ByteString Void IO ()
loop sum totalRef lastProgressTime = do
  mx <- await -- 等待数据块
  case mx of
    Nothing -> return () -- 无数据时结束
    Just x -> do
      -- 更新状态：累加当前数据块长度
      liftIO $ modifyIORef' totalRef (+ BS.length x)
      total <- liftIO $ readIORef totalRef
      t <- liftIO $ printProgress sum total lastProgressTime
      if total > sum
        then do
          return ()
        else loop sum totalRef t -- 递归处理下一个数据块

printProgress :: Int -> Int -> UTCTime -> IO UTCTime
printProgress sum received lastProgressTime = do
  now <- getCurrentTime
  if now `diffUTCTime` lastProgressTime > 0.5
    then do
      putStr $ formatSize received ++ " / " ++ formatSize sum ++ Prelude.replicate 5 ' ' ++ "\r"
      hFlush stdout
      return now
    else return lastProgressTime