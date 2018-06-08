{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE NamedFieldPuns           #-}
{-# LANGUAGE OverloadedStrings        #-}
{-# LANGUAGE RankNTypes               #-}
{-# LANGUAGE ScopedTypeVariables      #-}
{-# LANGUAGE TupleSections            #-}

module Docker.Client.Http where

-- import           Control.Monad.Base           (MonadBase(..), liftBaseDefault)
import           Control.Monad                (mapM)
import           Control.Monad.Catch          (MonadMask (..))
#if MIN_VERSION_http_conduit(2,3,0)
import           Control.Monad.IO.Unlift      (MonadUnliftIO, liftIO)
#endif
import           Control.Monad.Reader         (ReaderT (..), runReaderT)
import           Data.Aeson                  as JSON
import qualified Data.ByteString.Char8        as BSC
import qualified Data.ByteString.Lazy         as BL
import           Data.Conduit                 (Sink)
import           Data.Traversable             (sequenceA)
import           Data.Default.Class           (def)
import           Data.Maybe                   (fromMaybe)
import qualified Data.Map.Strict              as Map
import           Data.Monoid                  ((<>))
import           Data.Text.Encoding           (encodeUtf8)
import           Data.X509                    (CertificateChain (..))
import           Data.X509.CertificateStore   (makeCertificateStore)
import           Data.X509.File               (readKeyFile, readSignedObject)
import           Network.HTTP.Client          (defaultManagerSettings,
                                               managerRawConnection, method,
                                               newManager, parseRequest,
                                               requestBody, requestHeaders)
import qualified Network.HTTP.Client          as HTTP
import           Network.HTTP.Client.Internal (makeConnection)
import qualified Network.HTTP.Simple          as NHS
import           Network.HTTP.Types           (StdMethod, status101, status200,
                                               status201, status204)
import           Network.TLS                  (ClientHooks (..),
                                               ClientParams (..), Shared (..),
                                               Supported (..),
                                               defaultParamsClient)
import           Network.TLS.Extra            (ciphersuite_strong)
import           System.Directory             (doesFileExist, getHomeDirectory)
import           System.FilePath              ((</>))
import           System.Process               (readProcess)
import           System.X509                  (getSystemCertificateStore)

import           Control.Monad.Catch          (try)
import           Control.Monad.Except
import           Control.Monad.Reader.Class
import           Data.Text                    as T
import           Data.Typeable                (Typeable)
import qualified Network.HTTP.Types           as HTTP
import qualified Network.Socket               as S
import qualified Network.Socket.ByteString    as SBS


import           Docker.Client.Internal       (getAuthHeader,
                                               getEndpoint,
                                               getEndpointRequestBody,
                                               normalizeRegUrl)
import           Docker.Client.Types          --(DockerClientOpts, Endpoint (..),
                                               --apiVer, baseUrl, authMethod, DockerClientRegAuth(..))

type Request = HTTP.Request
type Response = HTTP.Response BL.ByteString
type HttpVerb = StdMethod
newtype HttpHandler m = HttpHandler (forall a . Request -> (HTTP.Response () -> Sink BSC.ByteString m (Either DockerError a)) -> m (Either DockerError a))

data DockerError = DockerConnectionError NHS.HttpException
                 | DockerInvalidRequest Endpoint
                 | DockerClientError Text
                 | DockerClientDecodeError Text -- ^ Could not parse the response from the Docker endpoint.
                 | DockerInvalidStatusCode HTTP.Status -- ^ Invalid exit code received from Docker endpoint.
                 | GenericDockerError Text deriving (Show, Typeable)

newtype DockerT m a = DockerT {
        unDockerT :: Monad m => ReaderT (DockerClientOpts, HttpHandler m) m a
    } deriving (Functor) -- Applicative, Monad, MonadReader, MonadError, MonadTrans

instance Applicative m => Applicative (DockerT m) where
    pure a = DockerT $ pure a
    (<*>) (DockerT f) (DockerT v) =  DockerT $ f <*> v

instance Monad m => Monad (DockerT m) where
    (DockerT m) >>= f = DockerT $ m >>= unDockerT . f
    return = pure

instance Monad m => MonadReader (DockerClientOpts, HttpHandler m) (DockerT m) where
    ask = DockerT ask
    local f (DockerT m) = DockerT $ local f m

instance MonadTrans DockerT where
    lift m = DockerT $ lift m

instance MonadIO m => MonadIO (DockerT m) where
    liftIO = lift . liftIO

-- instance MonadBase IO m => MonadBase IO (DockerT m) where
--     liftBase = liftBaseDefault

runDockerT :: Monad m => (DockerClientOpts, HttpHandler m) -> DockerT m a -> m a
runDockerT (opts, h) r = runReaderT (unDockerT r) (opts, h)

-- The reason we return Maybe Request is because the parseURL function
-- might find out parameters are invalid and will fail to build a Request
-- Since we are the ones building the Requests this shouldn't happen, but would
-- benefit from testing that on all of our Endpoints
mkHttpRequest :: HttpVerb -> Endpoint -> DockerClientOpts -> Maybe Request
mkHttpRequest verb e opts = request
        where headers = [("Content-Type", "application/json; charset=utf-8")]
                     <> fromMaybe [] (getAuthHeader (authInfo opts) e)
              fullE = T.unpack (baseUrl opts) ++ T.unpack (getEndpoint (apiVer opts) e)
              initialR = parseRequest fullE
              request' = case  initialR of
                            Just ir ->
                                return $ ir {method = (encodeUtf8 . T.pack $ show verb),
                                              requestHeaders = headers}
                            Nothing -> Nothing
              request = (\r -> maybe r (\body -> r {requestBody = body,  -- This will either be a HTTP.RequestBodyLBS  or HTTP.RequestBodySourceChunked for the build endpoint
                                                    requestHeaders = headers}) $ getEndpointRequestBody e) <$> request'
              -- Note: Do we need to set length header?

defaultHttpHandler :: (
#if MIN_VERSION_http_conduit(2,3,0)
    MonadUnliftIO m,
#endif
    MonadIO m, MonadMask m) => m (HttpHandler m)
defaultHttpHandler = do
    manager <- liftIO $ newManager defaultManagerSettings
    return $ httpHandler manager

httpHandler :: (
#if MIN_VERSION_http_conduit(2,3,0)
    MonadUnliftIO m,
#endif
    MonadIO m, MonadMask m) => HTTP.Manager -> HttpHandler m
httpHandler manager = HttpHandler $ \request' sink -> do -- runResourceT ..
    let request = NHS.setRequestManager manager request'
    try (NHS.httpSink request sink) >>= \res -> case res of
        Right res                              -> return res
#if MIN_VERSION_http_client(0,5,0)
        Left e@(HTTP.HttpExceptionRequest _ HTTP.ConnectionFailure{})  -> return $ Left $ DockerConnectionError e
#else
        Left e@HTTP.FailedConnectionException{}  -> return $ Left $ DockerConnectionError e
        Left e@HTTP.FailedConnectionException2{} -> return $ Left $ DockerConnectionError e
#endif
        Left e                                 -> return $ Left $ GenericDockerError (T.pack $ show e)

-- | Connect to a unix domain socket (the default docker socket is
--   at \/var\/run\/docker.sock)
--
--   Docker seems to ignore the hostname in requests sent over unix domain
--   sockets (and the port obviously doesn't matter either)
unixHttpHandler :: (
#if MIN_VERSION_http_conduit(2,3,0)
    MonadUnliftIO m,
#endif
    MonadIO m, MonadMask m) => FilePath -- ^ The socket to connect to
                -> m (HttpHandler m)
unixHttpHandler fp = do
  let mSettings = defaultManagerSettings
                    { managerRawConnection = return $ openUnixSocket fp}
  manager <- liftIO $ newManager mSettings
  return $ httpHandler manager

  where
    openUnixSocket filePath _ _ _ = do
      s <- S.socket S.AF_UNIX S.Stream S.defaultProtocol
      S.connect s (S.SockAddrUnix filePath)
      makeConnection (SBS.recv s 8096)
                     (SBS.sendAll s)
                     (S.close s)

-- TODO:
--  Move this to http-client-tls or network?
--  Add CA.
--  Maybe change this to: HostName -> PortNumber -> ClientParams -> IO (Either String TLSSettings)
clientParamsWithClientAuthentication :: S.HostName -> S.PortNumber -> FilePath -> FilePath -> IO (Either String ClientParams)
clientParamsWithClientAuthentication host port keyFile certificateFile = do
    keys <- readKeyFile keyFile
    cert <- readSignedObject certificateFile
    case keys of
        [key] ->
            -- TODO: load keys/path from file
            let params = (defaultParamsClient host $ BSC.pack $ show port) {
                    clientHooks = def
                        { onCertificateRequest = \_ -> return (Just (CertificateChain cert, key))}
                  , clientSupported = def
                        { supportedCiphers = ciphersuite_strong}
                  }
            in
            return $ Right params
        _ ->
            return $ Left $ "Could not read key file: " ++ keyFile

clientParamsSetCA :: ClientParams -> FilePath -> IO ClientParams
clientParamsSetCA params path = do
    userStore <- makeCertificateStore <$> readSignedObject path
    systemStore <- getSystemCertificateStore
    let store = userStore <> systemStore
    let oldShared = clientShared params
    return $ params { clientShared = oldShared
            { sharedCAStore = store }
        }


-- If the status is an error, returns a Just DockerError. Otherwise, returns Nothing.
statusCodeToError :: Endpoint -> HTTP.Status -> Maybe DockerError
statusCodeToError VersionEndpoint st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (ListContainersEndpoint _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (ListImagesEndpoint _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (CreateContainerEndpoint _ _) st =
    if st == status201 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (StartContainerEndpoint _ _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (StopContainerEndpoint _ _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (WaitContainerEndpoint _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (KillContainerEndpoint _ _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (RestartContainerEndpoint _ _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (PauseContainerEndpoint _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (UnpauseContainerEndpoint _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (ContainerLogsEndpoint _ _ _) st =
    if st == status200 || st == status101 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (DeleteContainerEndpoint _ _) st =
    if st == status204 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (InspectContainerEndpoint _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (BuildImageEndpoint _ _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (CreateImageEndpoint _ _ _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (TagImageEndpoint _ _ _) st =
    if st == status201 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st
statusCodeToError (PushImageEndpoint _ _) st =
    if st == status200 then
        Nothing
    else
        Just $ DockerInvalidStatusCode st

-- json format for the relevant portion of a docker config file
data DockerConfig = DockerConfig {
        credsStore :: String
    }
    deriving (Eq, Show)

instance FromJSON DockerConfig where
    parseJSON (JSON.Object o) = do
        credsStore <- o .: "credsStore"
        return $ DockerConfig credsStore
    parseJSON _ = fail "DockerConfig is not an object"

loadDockerConfig :: IO (Maybe DockerConfig)
loadDockerConfig = do
    configPath <- (</> ".docker/config.json") <$> getHomeDirectory
    configExists <- doesFileExist configPath
    case configExists of
        False -> return Nothing
        True -> JSON.decodeStrict . BSC.pack <$> readFile configPath

-- json format for the output of a docker auth helper
data HelperOutput = HelperOutput {
      username :: String
    , secret :: String
    }
    deriving (Eq, Show)

instance FromJSON HelperOutput where
    parseJSON (JSON.Object o) = do
        u <- o .: "Username"
        p <- o .: "Secret"
        return $ HelperOutput u p
    parseJSON _ = fail "HelperOutput is not an object"

getRegAuth :: String -> String -> IO (Maybe (Text, RegistryAuth))
getRegAuth credCommand regName = do
    outputStr <- readProcess credCommand ["get"] regName
    case JSON.eitherDecodeStrict (BSC.pack outputStr) of
        Left e -> error e
        Right HelperOutput{username,secret} ->
            let
              normalized :: Maybe Text
              normalized = normalizeRegUrl (T.pack regName)
            in
              return $ (, RegistryAuth username secret) <$> normalized

-- Reads a registry config from the docker credentials helper
-- First calls list to get all URLS and then calls get on each one of those
getRegConf :: DockerConfig -> IO (Maybe RegistryConfig)
getRegConf DockerConfig{credsStore} = do
    let
        credCommand = "docker-credential-" <> credsStore
    reposString <- readProcess credCommand ["list"] ""
    let
      maybeRepos :: Either String (Map.Map String String)
      maybeRepos = JSON.eitherDecodeStrict $ BSC.pack reposString
    case maybeRepos of
        Left e -> error e
        Right repos -> do
            pairsOfMaybes <- mapM (getRegAuth credCommand) $ Map.keys repos
            let
              maybePairs :: Maybe [(Text, RegistryAuth)]
              maybePairs = sequenceA pairsOfMaybes
            return $ RegistryConfig . Map.fromList <$> maybePairs

loadDockerAuth :: DockerAuthStrategy -> IO (Maybe RegistryConfig)
loadDockerAuth NoAuthStrategy = return Nothing
loadDockerAuth (ExplicitStrategy rc) = return $ Just rc
loadDockerAuth (DiscoverStrategy) = loadDockerConfig >>= maybe (return Nothing) getRegConf
