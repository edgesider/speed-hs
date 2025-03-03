{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Conduit as C
import Control.Applicative (liftA)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.State.Strict
import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString as BS
import qualified Data.ByteString.Lazy.UTF8 as U8
import qualified Data.Conduit.List as CL
import Data.HashMap.Strict (keys)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Text.IO as TIO
import Data.Time
import Network.HTTP.Simple
import System.IO (stdout)

jsonParse :: IO ()
jsonParse = do
  let res = decode $ U8.fromString "{\"你\":\"\"}" :: Maybe Value
  case res of
    Just (Object obj) -> mapM_ (TIO.putStrLn . K.toText) $ KM.keys obj
    Nothing -> print "failed to parse"

main :: IO ()
main = do
  req' <- parseRequest "https://test.ustc.edu.cn/backend/garbage.php?r=0.5811532106165538&ckSize=100"
  let req =
        setRequestMethod "get" $ setRequestHeader "Cookie" ["ustc=1"] req'

  start <- getCurrentTime

  totalRef <- newIORef 0
  httpSink req $ const $ loop totalRef
  total <- readIORef totalRef

  end <- getCurrentTime
  let diff = diffUTCTime end start

  print $
    show total
      ++ " bytes in "
      ++ show diff
      ++ " seconds"
      ++ ", speed is "
      ++ show (fromIntegral total / 1024.0 / 1024 / diff)
      ++ "MB/s"

loop :: IORef Int -> ConduitM ByteString Void IO ()
loop totalRef = do
  mx <- await -- 等待数据块
  case mx of
    Nothing -> return () -- 无数据时结束
    Just x -> do
      -- 更新状态：累加当前数据块长度
      liftIO $ modifyIORef' totalRef (+ BS.length x)
      total <- liftIO $ readIORef totalRef
      if total > 1024 * 1024 * 100
        then return ()
        else loop totalRef -- 递归处理下一个数据块
