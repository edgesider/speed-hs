module Utils where

import Text.Printf (printf)
import qualified Data.ByteString as BS
import Data.Conduit
import System.Random (randomRIO)

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

byteChunks :: Int -> ConduitT () BS.ByteString IO ()
byteChunks = loop
  where
    chunkSize = 1024 * 8
    loop remain
      | remain <= 0 = do
          yield $ BS.pack [] -- 多生成一个空块，以便下游能感知到最后一块发送完毕
      | otherwise = do
          let currentChunk = BS.replicate (min remain chunkSize) 30
          yield currentChunk
          loop (remain - chunkSize)

randomStr :: IO String
randomStr = do
  rand <- randomRIO (0, 1 :: Double)
  return $ printf "%f" rand