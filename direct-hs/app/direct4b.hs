{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

import           Control.Applicative    (optional, (<**>), (<|>))
import qualified Control.Exception      as E
import           Control.Monad          (forM_, join, void, (>=>))
import           Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Lazy   as B
import           Data.List              (intercalate)
import           Data.Maybe             (fromMaybe)
import qualified Data.MessagePack       as M
import qualified Data.MessagePack.RPC   as Msg
import qualified Data.Text              as T
import qualified Data.Text.Encoding     as TE
import qualified Data.Text.IO           as T
import qualified Data.Text.Lazy         as TL
import qualified Data.Text.Lazy.IO      as TL
import           Network.Mime           (defaultMimeLookup)
import qualified Options.Applicative    as Opt
import qualified System.Directory       as Dir
import           System.Envy            (FromEnv, decodeEnv, env, envMaybe,
                                         fromEnv, (.!=))
import           System.Exit            (die)
import           System.FilePath        ((</>))
import           System.IO              (BufferMode (NoBuffering), hGetEcho,
                                         hSetBuffering, hSetEcho, stderr, stdin,
                                         stdout)

import qualified Web.Direct             as D

main :: IO ()
main = join $ Opt.execParser optionsInfo
  where
    optionsInfo :: Opt.ParserInfo (IO ())
    optionsInfo = Opt.info
        (options <**> Opt.helper)
        (  Opt.fullDesc
        <> Opt.progDesc "Command line client for direct4b.com"
        <> Opt.header ""
        )

    options :: Opt.Parser (IO ())
    options =
        Opt.hsubparser
            $  Opt.command
                   "login"
                   (Opt.info
                       (login <$> loginInfoOption)
                       (Opt.briefDesc <> Opt.progDesc
                           "Create a JSON file required to login."
                       )
                   )
            <> Opt.command
                   "send"
                   (Opt.info
                       (sendText <$> loginInfoOption <*> Opt.argument
                           Opt.auto
                           (Opt.metavar "TALK_ID")
                       )
                       (  Opt.fullDesc
                       <> Opt.progDesc "Send a message from stdin."
                       )
                   )
            <> Opt.command
                   "observe"
                   (Opt.info
                       (observe <$> loginInfoOption)
                       (Opt.fullDesc <> Opt.progDesc
                           "Observe all messages for the logged-in user."
                       )
                   )
            <> Opt.command
                   "upload"
                   (Opt.info
                       (   uploadFile
                       <$> loginInfoOption
                       <*> optional
                               (Opt.strOption
                                   (  Opt.short 't'
                                   <> Opt.metavar "MESSAGE_TEXT"
                                   <> Opt.help
                                          "Message text attached to the uploaded file."
                                   )
                               )
                       <*> optional
                               (Opt.strOption
                                   (  Opt.short 'm'
                                   <> Opt.metavar "MIME_TYPE"
                                   <> Opt.help
                                          "MIME type for the uploaded file (default: \"application/octet-stream\")."
                                   )
                               )
                       <*> domainIdOption
                       <*> Opt.argument Opt.auto (Opt.metavar "TALK_ID")
                       <*> Opt.strArgument (Opt.metavar "FILE_PATH")
                       )
                       (Opt.fullDesc <> Opt.progDesc
                           "Send a file specified as FILE_PATH."
                       )
                   )
            <> Opt.command
                   "leave"
                   (Opt.info
                       (leave <$> loginInfoOption <*> Opt.argument
                           Opt.auto
                           (Opt.metavar "TALK_ID")
                       )
                       (Opt.fullDesc <> Opt.progDesc "Leave the talk room.")
                   )
            <> Opt.command
                   "ban"
                   (Opt.info
                       (   ban
                       <$> loginInfoOption
                       <*> Opt.argument Opt.auto (Opt.metavar "TALK_ID")
                       <*> Opt.argument Opt.auto (Opt.metavar "USER_ID")
                       )
                       (Opt.fullDesc <> Opt.progDesc
                           "Remove the user from the talk room."
                       )
                   )
            <> Opt.command
                   "get"
                   (Opt.info
                       (Opt.hsubparser
                           (  Opt.command
                                 "domains"
                                 (Opt.info
                                     (printDomains <$> loginInfoOption)
                                     Opt.briefDesc
                                 )
                           <> Opt.command
                                  "users"
                                  (Opt.info
                                      (   printUsers
                                      <$> loginInfoOption
                                      <*> domainIdOption
                                      )
                                      Opt.briefDesc
                                  )
                           <> Opt.command
                                  "talks"
                                  (Opt.info
                                      (   printTalkRooms
                                      <$> loginInfoOption
                                      <*> domainIdOption
                                      )
                                      Opt.briefDesc
                                  )
                           )
                       )
                       (  Opt.fullDesc
                       <> Opt.progDesc
                              "Display information on the logged-in user."
                       <> Opt.header ""
                       )
                   )


domainIdOption :: Opt.Parser (Maybe D.DomainId)
domainIdOption = optional $ Opt.option
    Opt.auto
    (  Opt.short 'd'
    <> Opt.metavar "DOMAIN_ID"
    <> Opt.help
           "Target Domain ID (default: the first domain obtained by `get_domains` RPC function)."
    )


loginInfoOption :: Opt.Parser FilePath
loginInfoOption =
    Opt.strOption
            (Opt.short 'l' <> Opt.metavar "LOGIN_INFO_FILE" <> Opt.help
                ("File to save/read information required to login direct4b.com (default: \""
                ++ defaultJsonFileName
                ++ "\")."
                )
            )
        <|> pure defaultJsonFileName


newtype EndpointUrl = EndpointUrl { getEndpointUrl :: String } deriving Show

instance FromEnv EndpointUrl where
  fromEnv _ =
    EndpointUrl <$> (envMaybe "DIRECT_ENDPOINT_URL" .!= "wss://api.direct4b.com/albero-app-server/api")


data Env =
  Env
    { directEmailAddress :: T.Text
    , directPassword     :: T.Text
    , directEndpointUrl  :: String
    } deriving Show

instance FromEnv Env where
  fromEnv _ =
    Env
      <$> (env "DIRECT_EMAIL_ADDRESS" <|> getEmailAddress)
      <*> (env "DIRECT_PASSWORD" <|> getPassword)
      <*> (getEndpointUrl <$> fromEnv Nothing)
    where
      getEmailAddress = liftIO $ do
        putStr "Enter direct email: "
        T.getLine
      getPassword = liftIO $ do
        putStr "Enter direct password: "
        t <- E.bracket
          (hGetEcho stdin)
          (hSetEcho stdin)
          (const (hSetEcho stdin False >> T.getLine))
        putStrLn ""
        return t


login :: FilePath -> IO ()
login jsonFileName = do
    hSetBuffering stdin  NoBuffering
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering

    e <- dieWhenLeft =<< decodeEnv
    let url = directEndpointUrl e
    putStrLn $ "Parsed URL:" ++ show url

    let config = D.defaultConfig { D.directEndpointUrl = url }
    loginInfo <- either E.throwIO return
        =<< D.login config (directEmailAddress e) (directPassword e)
    putStrLn "Successfully logged in."

    B.writeFile jsonFileName $ D.serializeLoginInfo loginInfo
    cd <- Dir.getCurrentDirectory
    putStrLn $ "Saved access token at '" ++ (cd </> jsonFileName) ++ "'."

sendText :: FilePath -> D.TalkId -> IO ()
sendText jsonFileName tid = do
    txt <- TL.stripEnd <$> TL.getContents
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ \client -> forM_ (TL.chunksOf 1024 txt)
        $ \chunk -> D.sendMessage client (D.Txt $ TL.toStrict chunk) tid

observe :: FilePath -> IO ()
observe jsonFileName = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    D.withClient
        D.defaultConfig { D.directLogger      = putStrLn
                        , D.directFormatter   = showMsg
                        , D.directEndpointUrl = url
                        }
        pInfo
        (\_ -> return ())

dieWhenLeft :: Either String a -> IO a
dieWhenLeft = either exitError return

exitError :: String -> IO a
exitError emsg = die $ "[ERROR] " ++ emsg ++ "\n"

defaultJsonFileName :: FilePath
defaultJsonFileName = ".direct4b.json"


showObjs :: [M.Object] -> String
showObjs objs = "[" ++ intercalate "," (map showObj objs) ++ "]"

showObj :: M.Object -> String
showObj (M.ObjectWord w)  = "+" ++ show w
showObj (M.ObjectInt  n)  = show n
showObj M.ObjectNil       = "nil"
showObj (M.ObjectBool  b) = show b
showObj (M.ObjectStr   s) = "\"" ++ T.unpack s ++ "\""
showObj (M.ObjectArray v) = "[" ++ intercalate "," (map showObj v) ++ "]"
showObj (M.ObjectMap   m) = "{" ++ intercalate "," (map showPair m) ++ "}"
    where showPair (x, y) = "(" ++ showObj x ++ "," ++ showObj y ++ ")"
showObj (M.ObjectBin _   ) = error "ObjectBin"
showObj (M.ObjectExt _ _ ) = error "ObjectExt"
showObj (M.ObjectFloat  _) = error "ObjectFloat"
showObj (M.ObjectDouble _) = error "ObjectDouble"

showMsg :: Msg.Message -> String
showMsg (Msg.RequestMessage _ method objs) =
    "request " ++ T.unpack method ++ " " ++ showObjs objs
showMsg (Msg.ResponseMessage _ (Left  obj)) = "response error " ++ showObj obj
showMsg (Msg.ResponseMessage _ (Right obj)) = "response " ++ showObj obj
showMsg (Msg.NotificationMessage method objs) =
    "notification " ++ T.unpack method ++ " " ++ showObjs objs


uploadFile
    :: FilePath         -- ^ The path to login info.
    -> Maybe T.Text     -- ^ Text message sent with the file.
    -> Maybe T.Text     -- ^ MIME type of the file.
    -> Maybe D.DomainId -- ^ The ID of domain onto which the file is uploaded. Default: the first domain obtained by `get_domains` RPC.
    -> D.TalkId         -- ^ The ID of talk room onto which the file is uploaded.
    -> FilePath         -- ^ The path to file.
    -> IO ()
uploadFile jsonFileName mtxt mmime mdid tid path = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directInitialDomainId          = mdid
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ \client -> do
        upf <- D.readToUpload
            mtxt
            (fromMaybe (TE.decodeUtf8 $ defaultMimeLookup $ T.pack path) mmime)
            path
        void (either E.throwIO return =<< D.uploadFile client upf tid)


leave :: FilePath -> D.TalkId -> IO ()
leave jsonFileName tid = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ \client -> do
        result <- D.leaveTalkRoom client tid
        case result of
            Right _               -> return ()
            Left  D.InvalidTalkId -> die "Talk room not found."
            Left  e               -> die $ "Unexpected Error: " ++ show e

ban :: FilePath -> D.TalkId -> D.UserId -> IO ()
ban jsonFileName tid uid = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ \client -> do
        result <- D.removeUserFromTalkRoom client tid uid
        case result of
            Right _               -> return ()
            Left  D.InvalidTalkId -> die "Talk room not found."
            Left D.InvalidTalkType ->
                die "Operation not permitted with PairTalk."
            Left D.InvalidUserId -> die "User not found."
            Left e               -> die $ "Unexpected Error: " ++ show e


printDomains :: FilePath -> IO ()
printDomains jsonFileName = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ D.getDomains >=> mapM_ (putStrLn . showDomain)

printUsers :: FilePath -> Maybe D.DomainId -> IO ()
printUsers jsonFileName mdid = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directInitialDomainId          = mdid
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ D.getUsers >=> mapM_ (putStrLn . showUser)

printTalkRooms :: FilePath -> Maybe D.DomainId -> IO ()
printTalkRooms jsonFileName mdid = do
    pInfo <- dieWhenLeft . D.deserializeLoginInfo =<< B.readFile jsonFileName
    (EndpointUrl url) <- dieWhenLeft =<< decodeEnv
    let config = D.defaultConfig { D.directEndpointUrl              = url
                                 , D.directInitialDomainId          = mdid
                                 , D.directWaitCreateMessageHandler = False
                                 }
    D.withClient config pInfo $ \client -> do
        talks <- D.getTalkRooms client
        forM_ talks $ \talk -> do
            talkUsers <- D.getTalkUsers client talk
            putStrLn $ showTalkRoom talk talkUsers

showDomain :: D.Domain -> String
showDomain domain =
    intercalate "\t" [show (D.domainId domain), T.unpack (D.domainName domain)]

showUser :: D.User -> String
showUser user = intercalate
    "\t"
    [ show (D.userId user)
    , T.unpack (D.displayName user)
    , T.unpack (D.phoneticDisplayName user)
    ]

showTalkRoom :: D.TalkRoom -> [D.User] -> String
showTalkRoom talk talkUsers = intercalate
    "\t"
    [ show (D.talkId talk)
    , showTalkType (D.talkType talk)
    , intercalate ", " $ map (T.unpack . D.displayName) talkUsers
    ]
  where
    showTalkType (D.GroupTalk name _settings) = "GroupTalk \"" ++ T.unpack name ++ "\""
    showTalkType other                        = show other
