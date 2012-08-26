{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where
import qualified Data.ByteString.Char8 as S8

import qualified Data.Text as T
import           Data.List (isPrefixOf, isSuffixOf)
import           Data.Maybe
import           Data.Version
import           Control.Monad

import           Hails.HttpServer
import           Hails.HttpServer.Auth
import           Hails.Version

import           Network.Wai.Handler.Warp

import           System.Posix.Env.ByteString (setEnv)
import           System.Environment
import           System.Console.GetOpt hiding (Option)
import qualified System.Console.GetOpt as GetOpt
import           System.IO (stderr, hPutStrLn)
import           System.FilePath
import           System.Directory
import           System.Exit


import           GHC
import           GHC.Paths
import           DynFlags
import           Unsafe.Coerce



about :: String -> String
about prog = prog ++ " " ++ showVersion version ++                   "\n\n\
 \Simple tool for launching Hails apps.  This tool can be used in       \n\
 \both development and production mode.  It allows you configure the    \n\
 \environment your app runs in (e.g., the port number the Hails HTTP    \n\
 \server should listen on, the MongoDB server it should connect to,     \n\
 \etc.). In development mode (default), " ++ prog ++ " uses some default\n\
 \settings (e.g., port 8080).  In production, mode all configuration    \n\
 \settings must be specified.  To simplify deployment, this tool        \n\
 \checks the program environment for configuration settings (e.g.,      \n\
 \variable PORT is used for the port number), but you can override      \n\
 \these with arguments. See \'" ++ prog ++ " --help\' for a list of     \n\
 \configuration settings and corresponding environment variables.     \n\n"
   ++ prog ++ " dynamically loads your app requst handler. Hence, the   \n\
 \app name is the module name where your \'server\' function is         \n\
 \defined."

--
--
--


main :: IO ()
main = do
  args <- getArgs
  env  <- getEnvironment
  opts <- do opts <- hailsOpts args env
             when (optAbout opts) $ printAbout
             opts' <- case optInFile opts of
               Nothing -> return opts
               Just file -> do envFromFile file
                               env' <- getEnvironment
                               print env'
                               hailsOpts args env'
             cleanOpts opts'
  maybe (return ()) (optsToFile opts) $ optOutFile opts
  putStrLn $ "Working environment:\n\n" ++ optsToEnv opts
  let port = fromJust $ optPort opts
      provider = T.pack . fromJust . optOpenID $ opts
      f = if optDev opts
               then devHailsApplication
               else (openIdAuth provider) . hailsApplicationToWai 
  app <- loadApp (optSafe opts) (optPkgConf opts) (fromJust $ optName opts)
  runSettings (defaultSettings { settingsPort = port })
              (f app)


-- | Given an application module name, load the main controller named
-- @server@.
loadApp :: Bool             -- -XSafe ?
        -> Maybe String     -- -package-config
        -> String           -- Application name
        -> IO Application
loadApp safe mpkgConf appName = runGhc (Just libdir) $ do
  dflags0 <- getSessionDynFlags
  let dflags1 = if safe
                  then dopt_set (dflags0 { safeHaskell = Sf_Safe })
                                Opt_PackageTrust
                  else dflags0
      dflags2 = case mpkgConf of
                  Just pkgConf ->
                    dopt_unset (dflags1 { extraPkgConfs =
                                            pkgConf : extraPkgConfs dflags1 })
                               Opt_ReadUserPackageConf
                  _ -> dflags1
  void $ setSessionDynFlags dflags2
  target <- guessTarget appName Nothing
  addTarget target
  r <- load LoadAllTargets
  case r of
    Failed -> fail "Compilation failed."
    Succeeded -> do
      setContext [IIDecl $ simpleImportDecl (mkModuleName appName)]
      value <- compileExpr (appName ++ ".server") 
      return . unsafeCoerce $ value


--
-- Parsing options
--

-- | Type used to encode hails options
data Options = Options
   { optName        :: Maybe String  -- ^ App name
   , optPort        :: Maybe Int     -- ^ App port number
   , optAbout       :: Bool          -- ^ About this program
   , optSafe        :: Bool          -- ^ Use @-XSafe@
   , optForce       :: Bool          -- ^ Force unsafe in production
   , optDev         :: Bool          -- ^ Development/Production
   , optOpenID      :: Maybe String  -- ^ OpenID provider
   , optDBConf      :: Maybe String  -- ^ Filepath of databases conf file
   , optPkgConf     :: Maybe String  -- ^ Filepath of package-conf
   , optMongoServer :: Maybe String  -- ^ MongoDB server URL
   , optCabalDev    :: Maybe String  -- ^ Cabal-dev directory
   , optOutFile     :: Maybe String  -- ^ Write configurate to file
   , optInFile      :: Maybe String  -- ^ Read configurate from file
   } deriving Show

-- | Default options
defaultOpts :: Options
defaultOpts = Options { optName        = Nothing
                      , optPort        = Nothing
                      , optAbout       = False
                      , optSafe        = True
                      , optForce       = False
                      , optDev         = True
                      , optOpenID      = Nothing
                      , optDBConf      = Nothing
                      , optPkgConf     = Nothing
                      , optCabalDev    = Nothing
                      , optMongoServer = Nothing 
                      , optOutFile     = Nothing
                      , optInFile      = Nothing}

-- | Default development options. These options can be used 
-- when in development mode, to avoid annoying the user.
defaultDevOpts :: Options
defaultDevOpts = Options { optName        = Just "App"
                         , optPort        = Just 8080
                         , optAbout       = False
                         , optSafe        = True
                         , optForce       = False
                         , optDev         = True
                         , optOpenID      = Just "http://localhost"
                         , optDBConf      = Just "database.conf"
                         , optPkgConf     = Nothing
                         , optCabalDev    = Nothing
                         , optMongoServer = Just "localhost"
                         , optOutFile     = Nothing
                         , optInFile      = Nothing}


-- | Parser for options
options :: [ OptDescr (Options -> Options) ]
options = 
  [ GetOpt.Option ['a'] ["app"]
      (ReqArg (\n o -> o { optName = Just n }) "APP_NAME")
      "Start application APP_NAME."
  , GetOpt.Option ['p'] ["port"]
      (ReqArg (\p o -> o { optPort = Just $ read p }) "PORT")
      "Run application on port PORT."
  , GetOpt.Option []    ["dev", "development"]
        (NoArg (\opts -> opts { optDev = True }))
        "Development mode, default (no authentication)."
  , GetOpt.Option []    ["prod", "production"]
        (NoArg (\opts -> opts { optDev = False }))
        "Production mode (OpenID authentication). Must set OPENID_PROVIDER."
  , GetOpt.Option [] ["openid-provider"]
      (ReqArg (\u o -> o { optOpenID = Just u }) "OPENID_PROVIDER")
      "Set OPENID_PROVIDER as the OpenID provider."
  , GetOpt.Option []    ["unsafe"]
        (NoArg (\opts -> opts { optSafe = False }))
        "Turn the -XSafe flag off."
  , GetOpt.Option []    ["force"]
        (NoArg (\opts -> opts { optForce = True }))
        "Use with --unsafe to force the -XSafe flag off in production mode."
  , GetOpt.Option [] ["package-conf"]
      (ReqArg (\n o -> o { optPkgConf = Just n }) "PACKAGE_CONF")
        "Use PACKAGE_CONF for as the app specific package-conf file."
  , GetOpt.Option ['s'] ["cabal-dev"]
      (ReqArg (\n o -> o { optCabalDev = Just n }) "CABAL_DEV_SANDBOX")
        "The location ofthe cabal-dev sandbox (e.g., ./cabal-dev)."
  , GetOpt.Option [] ["db-conf", "database-conf"]
      (ReqArg (\n o -> o { optDBConf = Just n }) "DATABASE_CONFIG_FILE")
        "Use DATABASE_CONFIG_FILE  as the specific database.conf file."
  , GetOpt.Option [] ["db", "mongodb-server"]
      (ReqArg (\n o -> o { optMongoServer = Just n }) "HAILS_MONGODB_SERVER")
        "Use HAILS_MONGODB_SERVER as the URL to the MongoDB server."
  , GetOpt.Option [] ["out"]
      (ReqArg (\n o -> o { optOutFile = Just n }) "OUT_FILE")
        "Write options to environment file OUT_FILE."
  , GetOpt.Option [] ["in", "env", "environment"]
      (ReqArg (\n o -> o { optInFile = Just n }) "IN_FILE")
        "Load environment variables from file IN_FILE."
  , GetOpt.Option ['?']    ["about"]
        (NoArg (\opts -> opts { optAbout = True }))
        "About this program."
  ]

-- | Do parse options
hailsOpts :: [String] -> [(String, String)] -> IO Options
hailsOpts args env =
  let opts = envOpts defaultOpts env
  in case getOpt Permute options args of
       (o,[], []) -> return $ foldl (flip id) opts o
       (_,_,errs) -> do prog <- getProgName
                        hPutStrLn stderr $ concat errs ++
                                           usageInfo (header prog) options
                        exitFailure
    where header prog = "Usage: " ++ prog ++ " [OPTION...]"


-- | Extracting options from the environment (prioritzed) over
-- arguments
envOpts :: Options -> [(String, String)] -> Options
envOpts opts env = 
  opts { optName        = mFromEnvOrOpt "APP_NAME" optName
       , optPort        = case readFromEnv "PORT" of
                            p@(Just _) -> p
                            _ -> optPort opts
       , optOpenID      = mFromEnvOrOpt "OPENID_PROVIDER" optOpenID 
       , optDBConf      = mFromEnvOrOpt "DATABASE_CONFIG_FILE" optDBConf
       , optPkgConf     = mFromEnvOrOpt "PACKAGE_CONF" optPkgConf
       , optCabalDev    = mFromEnvOrOpt "CABAL_DEV_SANDBOX" optCabalDev
       , optMongoServer = mFromEnvOrOpt "HAILS_MONGODB_SERVER" optMongoServer
       }
    where fromEnv n = lookup n env
          readFromEnv n = lookup n env >>= mRead
          mRead :: Read a => String -> Maybe a
          mRead s = fst `liftM` (listToMaybe $ reads s)
          mFromEnvOrOpt evar f = case fromEnv evar of
                                   x@(Just _) -> x
                                   _ -> f opts

cleanOpts :: Options -> IO Options
cleanOpts opts = do
  when (optAbout opts) $ printAbout
  if optDev opts 
    then cleanDevOpts opts
    else cleanProdOpts opts

-- | Clean options and use default development options when
-- non-existant.
cleanDevOpts :: Options -> IO Options
cleanDevOpts opts0 = do
  let opts1 = opts0 { optName        = mergeMaybe optName
                    , optPort        = mergeMaybe optPort
                    , optOpenID      = mergeMaybe optOpenID
                    , optDBConf      = mergeMaybe optDBConf
                    , optMongoServer = mergeMaybe optMongoServer }
  case (optPkgConf opts1, optCabalDev opts1) of
    (Just _, Just _) -> do
      hPutStrLn stderr "Flag package-conf supplied, ignoring cabal-dev sandbox"
      return $ opts1 { optCabalDev = Nothing }
    (_, Just cd) -> do
      pkgConf <- findPackageConfInCabalDev cd
      return $ opts1 { optCabalDev = Nothing, optPkgConf = Just pkgConf }
    _ -> return opts1
  where mergeMaybe f = f $ if isJust (f opts0)
                             then opts0
                             else defaultDevOpts

-- | Clean options and strictly check that all the necessary ones
-- exist.
cleanProdOpts :: Options -> IO Options
cleanProdOpts opts0 = do
  checkIsJust optName        "APP_NAME"
  checkIsJust optPort        "PORT"
  checkIsJust optOpenID      "OPENID_PROVIDER"
  checkIsJust optDBConf      "DATABASE_CONFIG_FILE"
  checkIsJust optMongoServer "HAILS_MONGODB_SERVER"
  unless (optSafe opts0 || optForce opts0) $ do
    hPutStrLn stderr "Production code must be Safe, use --force to override"
    exitFailure
  case (optPkgConf opts0, optCabalDev opts0) of
    (Just _, Just _) -> do
      hPutStrLn stderr "Both package-conf supplied and cabal-dev sandbox defined."
      exitFailure
    (_, Just cd) -> do
      pkgConf <- findPackageConfInCabalDev cd
      return $ opts0 { optCabalDev = Nothing, optPkgConf = Just pkgConf }
    _ -> return opts0
    where checkIsJust f msg =
            when (isNothing $ f opts0) $ do
              hPutStrLn stderr $ "Production mode is strict, missing " ++ msg
              exitFailure


-- | Find the package-conf file in a cabal-dev directory (e.g.,
-- packages-7.4.2.conf)
findPackageConfInCabalDev :: FilePath -> IO FilePath
findPackageConfInCabalDev cdev = do
  fs <- getDirectoryContents cdev
  case filter f fs of
    []     -> do
      hPutStrLn stderr $ "Could not file package config file in " ++ show cdev
      exitFailure
    xs@(x:_)  -> do 
      let path = cdev </> x
      when (length xs > 1) $ hPutStrLn stderr $ "Using " ++ show path ++
                                                " for the package config file"
      return path
  where f d = "packages-" `isPrefixOf` d && ".conf" `isSuffixOf` d
  
-- | Print about message
printAbout :: IO ()
printAbout = do
  prog <- getProgName
  putStrLn $ about prog
  exitSuccess

-- | Write options to environment file
optsToFile :: Options -> FilePath -> IO ()
optsToFile opts file = writeFile file (optsToEnv opts) >> exitSuccess

-- | Options to envionment string
optsToEnv :: Options -> String
optsToEnv opts = unlines $ filter (not .null) $ [
   toLine optName        "APP_NAME"
  ,maybe "" (("PORT = "++) . show) $ optPort opts
  ,toLine optOpenID      "OPENID_PROVIDER"
  ,toLine optDBConf      "DATABASE_CONFIG_FILE"
  ,toLine optMongoServer "HAILS_MONGODB_SERVER"
  ,toLine optPkgConf     "PACKAGE_CONF"
  ,toLine optCabalDev    "CABAL_DEV_SANDBOX" ]
    where toLine f var = maybe "" ((var ++ " = ")++) $ f opts

-- If an environment entry does not contain an @\'=\'@ character,
-- the @key@ is the whole entry and the @value@ is the empty string.
envFromFile :: FilePath -> IO ()
envFromFile file = do
  ls <- S8.lines `liftM` S8.readFile file
  forM_ ls $ \line ->
    let (key',val') = S8.span (/='=') line
        val = safeTail val'
    in case S8.words key' of
         [key] -> setEnv key val True
         _ -> do hPutStrLn stderr $ "Invalid environment line: " ++
                                    show (S8.unpack line)
                 exitFailure
      where safeTail s = if S8.null s then s else S8.tail s 
