{-# LANGUAGE CPP                   #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

-- ------------------------------------------------------------

module Hayoo.Hunt.Output
where

import           Control.Monad.IO.Class     (MonadIO, liftIO)
import           Data.Aeson                 (ToJSON, decode, encode)
import           Data.Aeson.Encode.Pretty   (Config (..), Indent (..),
                                             defConfig, encodePretty', keyOrder)
import qualified Data.ByteString.Lazy       as LB
import qualified Data.ByteString.Lazy.Char8 as LC
import           Data.Maybe                 (fromJust)
import           Data.Text                  (Text)
import           Hunt.Interpreter.Command   (CmdError (..), CmdRes (..))
import           Network.Browser            (browse, request, setOutHandler)
import           Network.HTTP
import           Network.URI                (parseURIReference)
import           System.Directory           (createDirectoryIfMissing)
import           System.FilePath            (splitFileName, (<.>), (</>))

-- ------------------------------------------------------------

outputValue :: (Functor m, MonadIO m, ToJSON c) => Either String String -> c -> m (Maybe LB.ByteString)
outputValue (Left fn) c = liftIO (jsonOutput True toFile c)
                          >> return Nothing
    where
      toFile bs
          = do createDirectoryIfMissing True dirPath
               LB.writeFile file bs
          where
            (dirPath, _) = splitFileName file
            file         = jsonPath fn

outputValue (Right uri) c = Just <$> liftIO (jsonOutput False toServer c)
    where
      toServer bs
          = postToServer $ mkPostReq (jsonUri uri) bs

jsonPath :: String -> String
jsonPath fn = "json" </> fn <.> "js"

jsonUri :: String -> String
jsonUri uri = uri </> "eval"

evalOkRes :: MonadIO m => Maybe LB.ByteString -> m ()
evalOkRes Nothing
    = return ()
evalOkRes (Just bs)
    | isOkMsg bs = return ()
    | otherwise  = liftIO . ioError . userError $
                  "server error: \"ok\" expected, but got " ++ show (LC.unpack bs)
    where
      isOkMsg s = maybe False ((== "ok") . unCmdRes) js
          where
            js :: Maybe (CmdRes Text)
            js = decode s

evalErrRes :: MonadIO m => Int -> LB.ByteString -> m a
evalErrRes rc bs
    = liftIO . ioError . userError $
      unwords ["server error: rc=", show rc, "msg=", msg ce]
    where
      ce :: Maybe CmdError
      ce = decode bs

      msg Nothing  = "result is not a JSON error message"
      msg (Just e) = show e

-- ------------------------------------------------------------

jsonOutput :: (ToJSON c) => Bool -> (LB.ByteString -> IO a) -> c -> IO a
jsonOutput pretty io x
    = io $ (if pretty then encodePretty' encConfig else encode) x
      where
#if MIN_VERSION_aeson_pretty(0, 8, 0)
        indent = Spaces 2
#else
        indent = 2
#endif

        encConfig :: Config
        encConfig
            = defConfig { confIndent = indent
                        , confCompare = keyOrder ["description", "index", "uri"]
                                       `mappend`
                                       compare
                        }

-- ------------------------------------------------------------

type Req = Request  Bytes
type Res = Response Bytes

type Bytes = LB.ByteString

mkPostReq :: String -> Bytes -> Req
mkPostReq uri bs
    = replaceHeader HdrContentType   "application/json" $
      replaceHeader HdrAccept        "application/json" $
      replaceHeader HdrUserAgent     "hayooCrawler/0.0.0.1" $
      setBody $
      mkReq
    where
      mkReq :: Req
      mkReq
          = mkRequest POST
            (fromJust $ parseURIReference $ uri)

      setBody :: Req -> Req
      setBody rq
          = replaceHeader HdrContentLength (show l) $
            rq { rqBody = bs }
          where
            l = LB.length bs

postToServer :: Req -> IO Bytes
postToServer req
    = do res <- snd `fmap`
                (browse $ do setOutHandler (const $ return ()) -- disable trace output
                             request req
                )
         case rspCode res of
           (2,0,0) -> return $ rspBody res
           (i,j,k) -> evalErrRes ((i * 10 + j) * 10 + k) (rspBody res)

defaultServer :: String
defaultServer = "http://localhost:3000/"

-- ------------------------------------------------------------

{-
main :: IO ()
main
    = do bs <- L.readFile "../test/ttt.js"
         -- print req
         -- (_, res) <- browse $ request req
         -- print res
         res <- postToServer $ mkPostReq defaultServer "insert" bs
         print res
-- -}

-- ------------------------------------------------------------
