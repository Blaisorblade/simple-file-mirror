-- Enable various language extensions. We're using some pretty
-- standard Haskell extensions here, nothing too esoteric.
{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE TemplateHaskell   #-}

-- Import some modules. A few things to note:
--
-- * We're using ClassyPrelude.Conduit instead of the standard
-- Prelude, which provides us with quite a bit more out of the box,
-- especially for our conduit usage.
--
-- * In order to make it clear where things are coming from, we're
-- using explicit imports or qualified imports (besides the prelude
-- import). You're free to be lazy and simply do something like
-- `import System.Directory`.
import           ClassyPrelude.Conduit
import qualified Data.ByteString.Builder    as BB
import           Data.Conduit.Blaze         (builderToByteString)
import           Data.Conduit.Network       (appSink, appSource, clientSettings,
                                             runTCPClient, runTCPServer,
                                             serverSettings)
import           Data.Word8                 (_0, _9, _colon, _hyphen)
import           Options.Applicative.Simple (addCommand, argument, auto,
                                             metavar, simpleOptions,
                                             simpleVersion, str)
import           Paths_dumb_file_mirror     (version)
import           System.Directory           (canonicalizePath,
                                             createDirectoryIfMissing,
                                             doesFileExist, removeFile)
import           System.Environment         (withArgs)
import           System.FilePath            (addTrailingPathSeparator,
                                             takeDirectory)
import qualified System.FSNotify            as FS
import           System.IO                  (IOMode (ReadMode), hFileSize,
                                             openBinaryFile)
import           System.IO.Temp             (withSystemTempDirectory)
import           Test.Hspec                 (hspec, it, shouldBe)
import           Test.Hspec.QuickCheck      (prop)

-- | The main function is the entrypoint to our program. We're going
-- to parse command line arguments and then perform the appropriate
-- action.
main :: IO ()
main = do
    -- Use the simpleOptions function to parse the command line
    -- arguments. We have multiple subcommands, but no flags,
    -- therefore we're using the unit value () here. The cmd will end
    -- up being the function to run next.
    ((), cmd) <- simpleOptions

        -- Version of the executable. This $(...) syntax is Template
        -- Haskell, and the simpleVersion function will look up Git
        -- commit information at compile time, making the
        -- dumb-file-mirror --version output much more useful:
        --
        -- $ dumb-file-mirror --version
        -- Version 0.1.0.0, Git revision 7320af1acc8de1c1cd37f44590f5799f7493cc98 (dirty)
        $(simpleVersion version)

        -- A one-line header for the --help output
        "dumb-file-mirror: Mirror file changes to a local host"

        -- Longer description for the --help output
        desc

        -- No options, so we just use the unit value ()
        (pure ())

        -- Parse the available commands.
        $ do

            -- Remote command, takes port and directory arguments.
            addCommand "remote" "Receive file changes" id

                -- This <$> and <*> syntax allows us to build up a
                -- result. It is known as applicative syntax, and
                -- applies a function to some wrapped-up values. In
                -- this case, the portArg and dirArg values are
                -- instructions on how to parse the command line
                -- arguments, not the actual port and directory.
                (remote <$> portArg <*> dirArg)

            -- Local command, takes host, port, and directory arguments
            addCommand "local" "Send file changes" id
                (local <$> hostArg <*> portArg <*> dirArg)

            -- Run the test suite. Unorthodox to include the test
            -- suite in the main executable, but makes for a
            -- single-file example.
            addCommand "test" "Run the test suite" id $ pure spec

    -- Run the action returned by the command line parser (remote,
    -- local, or spec).
    cmd
  where
    -- This describes how we parse each of the command line
    -- arguments. To see how this affects output:
    --
    -- $ dumb-file-mirror local
    -- Missing: HOST PORT DIRECTORY
    --
    -- Usage: dumb-file-mirror local HOST PORT DIRECTORY
    --   Send file changes
    hostArg = argument str (metavar "HOST")
    portArg = argument auto (metavar "PORT")
    dirArg = argument str (metavar "DIRECTORY")

-- | A longer description of the program, referenced above in main.
desc :: String
desc = unlines
    [ "This program will mirror local file changes to a remote host."
    , "By keeping a persistent TCP connection open between the local"
    , "and remote machines, latency is reduced versus more naive"
    , "solutions, like combining inotify and rsync."
    , "Note that this tool does not perform an initial file copy, if"
    , "needed you should do an explicit scp -r before using this tool."
    ]

-- | Run the remote portion, which listens on the given port and
-- writes files to the given directory.
remote :: Int -- ^ port to listen on
       -> FilePath -- ^ root directory to write files to
       -> IO ()
remote port dir =
    -- Launch a TCP server and use the given run function for each
    -- connection. `handleAny print` is used to display any exceptions
    -- on the console.
    runTCPServer settings (handleAny print . run)
  where
    -- define some server settings that say to listen to all network
    -- interfaces (*) on the given port
    settings = serverSettings port "*"

    -- Our run function is given an `appData` value, which lets us communicate with the peer on the network.
    run appData =
        -- runResourceT creates a scoped area where scarce resources -
        -- like file descriptors - can be allocated, and are
        -- guaranteed to be freed. This allows for easy exception
        -- safety, and complicated control flows to work
        -- seemlessly. In particular, the bracketP function relies on
        -- this function being used.
        runResourceT

        -- This streams out all data from the peer as a stream of
        -- ByteStrings (array of bytes).
      $ appSource appData

        -- We connect (with the $$ operator) our input stream with
        -- this _sink_. Our sink repeatedly runs recvFile until the
        -- stream is closed. Each call to recvFile reads a new file
        -- from the stream and writes it to disk.
     $$ foreverCE (recvFile dir)

-- | Run the local portion: connect to the remote process, watch for
-- file changes, and on each change send the updated contents to the
-- remote process.
local :: String -- ^ host to connect to
      -> Int -- ^ port to connect to
      -> FilePath -- ^ root directory
      -> IO ()
local host port dir =
    -- Create a connection to the remote process
    runTCPClient settings $ \appData ->
           runResourceT

           -- Get a stream providing the file path of each file
           -- changed on the filesystem.
         $ sourceFileChanges dir

           -- Wait for every new changed file, and then call sendFile
           -- on it to create the binary data to be sent to the
           -- client.
        $$ awaitForever (sendFile dir)

           -- To allow for efficient concatenation, Haskell offers a
           -- Builder value which efficiently fills up a buffer
           -- instead of performing multiple buffer copies. This is
           -- similar to the StringBuilder class from Java. This
           -- function converts a stream of Builder values into
           -- completed ByteString values.
        =$ builderToByteString

           -- Send the data to the remote process
        =$ appSink appData
  where
    -- We receive the hostname as character data on the console, but
    -- the network talks in bytes. Let's convert that String to a
    -- ByteString by assuming a UTF-8 encoding.
    hostBytes = encodeUtf8 (pack host)

    -- And now use that hostBytes to create connection settings for
    -- the requested host/port combo
    settings = clientSettings port hostBytes

---------------------------------------
-- CONDUIT UTILITY FUNCTIONS
---------------------------------------

-- | Watch for changes to a directory, and yield the file paths
-- downstream.
sourceFileChanges :: MonadResource m
                  => FilePath
                  -> Producer m FilePath
sourceFileChanges root =
  -- The bracketP function allows us to safely allocate some resource
  -- and guarantee it will be cleaned up. In our case, we are calling
  -- startManager to allocate a file watching manager, and stopManager
  -- to clean it up. These functions will under the surface tie in to
  -- OS-specific file watch mechanisms, such as inotify on Linux.
  bracketP FS.startManager FS.stopManager $ \man -> do
    -- Get the absolute path of the root directory
    root' <- liftIO $ canonicalizePath root

    -- Create a channel for communication between two threads. Since
    -- file watch events come in asynchronously on separate threads,
    -- we want to fill up a channel with those events, and then below
    -- read the values off that channel.
    chan <- liftIO newTChanIO

    -- Start watching a directory tree, accepting all events (const True).
    liftIO $ void $ FS.watchTree man root' (const True) $ \event -> do
        -- The complete file path of the event.
        let fp = FS.eventPath event

        -- Since we want the path relative to the directory root,
        -- strip off the root from the file path
        case stripPrefix (addTrailingPathSeparator root') fp of
            Nothing -> error $ "sourceFileChanges: prefix not found " ++ show (root', fp)
            Just suffix
                -- Ignore changes to the root directory itself
                | null suffix -> return ()

                -- Got a change to the file, write it to the channel
                | otherwise -> atomically $ writeTChan chan suffix

    -- Read the next value off the channel and yield it downstream,
    -- repeating forever.
    forever $ do
        suffix <- atomically $ readTChan chan
        yield suffix

-- | Keep performing the given action as long as more data exists on
-- the stream.
foreverCE :: Monad m => Sink ByteString m () -> Sink ByteString m ()
foreverCE inner =
    loop
  where
    loop = do
        -- peek the next byte off the stream, but don't remove it.
        mnext <- peekCE
        case mnext of
            -- Nothing else, exit!
            Nothing -> return ()
            Just _next -> do
                -- Had another byte, perform the inner action and then
                -- repeat.
                inner
                loop

sendFile :: MonadResource m
         => FilePath -- ^ root
         -> FilePath -- ^ relative
         -> Producer m BlazeBuilder
sendFile root fp = do
    sendFilePath fp

    let open = tryIO $ openBinaryFile fpFull ReadMode
        close (Left _err) = return ()
        close (Right h) = hClose h

    bracketP open close $ \eh ->
        case eh of
            Left _ex -> sendInteger (-1)
            Right h -> do
                size <- liftIO $ hFileSize h
                sendInteger size
                sourceHandle h =$= mapC BB.byteString
    yield flushBuilder
  where
    fpFull = root </> fp

sendInteger :: Monad m => Integer -> Producer m BlazeBuilder
sendInteger i = yield $ BB.integerDec i <> BB.word8 _colon

sendFilePath :: Monad m => FilePath -> Producer m BlazeBuilder
sendFilePath fp = do
    let bs = encodeUtf8 $ pack fp :: ByteString
    sendInteger $ fromIntegral $ length bs
    yield $ toBuilder bs

recvFile :: MonadResource m
         => FilePath -- ^ root
         -> Sink ByteString m ()
recvFile root = do
    fpRel <- recvFilePath
    let fp = root </> fpRel
    fileLen <- recvInteger
    if fileLen == (-1)
        then liftIO $ void $ tryIO $ removeFile fp
        else do
            liftIO $ createDirectoryIfMissing True $ takeDirectory fp
            takeCE fileLen =$= sinkFile fp

recvInteger :: (MonadThrow m, Integral i) => Sink ByteString m i
recvInteger = do
    mnext <- peekCE
    next <-
        case mnext of
            Nothing -> throwM EndOfStream
            Just next -> return next
    isNeg <-
        if next == _hyphen
            then do
                dropCE 1
                return True
            else return False

    x <- takeWhileCE (/= _colon) =$= foldMCE addDigit 0

    mw <- headCE
    unless (mw == Just _colon) (throwM (MissingColon mw))

    return $! if isNeg then negate x else x
  where
    addDigit total w
        | _0 <= w && w <= _9 = return (total * 10 + fromIntegral (w - _0))
        | otherwise = throwM (InvalidByte w)

recvFilePath :: MonadThrow m => Sink ByteString m FilePath
recvFilePath = do
    fpLen <- recvInteger
    fpRelText <- takeCE fpLen =$= decodeUtf8C =$= foldC
    return $ unpack fpRelText

data RecvIntegerException = InvalidByte Word8
                          | MissingColon (Maybe Word8)
                          | EndOfStream
    deriving (Show, Typeable)
instance Exception RecvIntegerException

---------------------------------------
-- TEST SUITE
---------------------------------------

spec :: IO ()
spec = withArgs [] $ hspec $ do
    prop "sendInteger/recvInteger is idempotent" $ \i -> do
        res <- sendInteger i $$ builderToByteString =$ recvInteger
        res `shouldBe` i
    prop "sendFilePath/recvFilePath is idempotent" $ \fp -> do
        res <- sendFilePath fp $$ builderToByteString =$ recvFilePath
        res `shouldBe` fp
    it "create and delete files" $
      withSystemTempDirectory "src" $ \srcDir ->
      withSystemTempDirectory "dst" $ \dstDir -> do

        let relPath = "somepath.txt"
            content = "This is the content of the file" :: ByteString

        writeFile (srcDir </> relPath) content

        runResourceT
            $ sendFile srcDir relPath
           $$ builderToByteString
           =$ recvFile dstDir

        content' <- readFile (dstDir </> relPath)
        content' `shouldBe` content

        removeFile (srcDir </> relPath)

        runResourceT
            $ sendFile srcDir relPath
           $$ builderToByteString
           =$ recvFile dstDir

        exists <- doesFileExist (dstDir </> relPath)
        exists `shouldBe` False
    it "sourceFileChanges" $ withSystemTempDirectory "source-file-changes" $ \root -> do
        chan <- newTChanIO
        let actions =
                [ ("foo", Just "hello")
                , ("bar", Just "world")
                , ("foo", Just "!")
                , ("bar", Nothing)
                , ("foo", Nothing)
                ]
        runConcurrently $
            Concurrently (runResourceT $ sourceFileChanges root $$ mapM_C (atomically . writeTChan chan)) <|>
            Concurrently (forM_ actions $ \(path, mcontents) -> do
                threadDelay 100000
                case mcontents of
                    Nothing -> removeFile (root </> path)
                    Just contents -> writeFile (root </> path) (contents :: ByteString)) <|>
            Concurrently (forM_ actions $ \(expected, _) -> do
                actual <- atomically $ readTChan chan
                actual `shouldBe` expected)
