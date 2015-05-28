module Main (main) where

import Control.Arrow
import Control.Monad
import Data.Maybe
import Data.Typeable (Typeable)
import Test.Hspec
import Test.Hspec.QuickCheck
import Web.PathPieces
import Web.ServerSession.Core.Internal
import Web.ServerSession.Core.StorageTests

import qualified Control.Exception as E
import qualified Crypto.Nonce as N
import qualified Data.ByteString.Char8 as B8
import qualified Data.IORef as I
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Time as TI
import qualified Test.QuickCheck.Property as Q


main :: IO ()
main = hspec $ parallel $ do
  -- State using () as storage.  As () is not a Storage instance,
  -- this is the state to be used when testing functions that
  -- should not touch the storage in any code path.
  stnull <- runIO $ createState ()

  -- State using TNTStorage.  This state should be used for
  -- functions that normally need to access the storage but on
  -- the test code path should not do so.
  sttnt <- runIO $ createState TNTStorage

  -- Some functions take a time argument meaning "now".  We don't
  -- gain anything using real "now", so here's a fake "now".
  let fakenow = read "2015-05-27 17:55:41 UTC" :: TI.UTCTime

  describe "SessionId" $ do
    gen <- runIO N.new
    it "is generated with 24 bytes from letters, numbers, dashes and underscores" $ do
      let reps = 10000
      sids <- replicateM reps (generateSessionId gen)
      -- Test length to be 24 bytes.
      map (T.length . unS) sids `shouldBe` replicate reps 24
      -- Test that we see all chars, and only the expected ones.
      -- The probability of a given character not appearing on
      -- this test is (63/64)^(24*reps), so it's extremely
      -- unlikely for this test to fail on correct code.
      let observed = S.fromList $ concat $ T.unpack . unS <$> sids
          expected = S.fromList $ ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ "-_"
      observed `shouldBe` expected

    prop "accepts as valid the session IDs generated by ourselves" $
      Q.ioProperty $ do
        sid <- generateSessionId gen
        return $ fromPathPiece (toPathPiece sid) Q.=== Just sid

    it "does not accept as valid some example invalid session IDs" $ do
      let parse = fromPathPiece :: T.Text -> Maybe SessionId
      parse ""                          `shouldBe` Nothing
      parse "123456789-123456789-123"   `shouldBe` Nothing
      parse "123456789-123456789-12345" `shouldBe` Nothing
      parse "aaaaaaaaaaaaaaaaaa*aaaaa"  `shouldBe` Nothing
      -- sanity check
      parse "123456789-123456789-1234"  `shouldSatisfy` isJust
      parse "aaaaaaaaaaaaaaaaaaaaaaaa"  `shouldSatisfy` isJust

  describe "State" $ do
    it "has the expected default values" $ do
      -- A silly test to avoid unintended change of default values.
      cookieName stnull        `shouldBe` "JSESSIONID"
      authKey stnull           `shouldBe` "_ID"
      idleTimeout stnull       `shouldBe` Just (60*60*24*7)
      absoluteTimeout stnull   `shouldBe` Just (60*60*24*60)
      persistentCookies stnull `shouldBe` True
      httpOnlyCookies stnull   `shouldBe` True
      secureCookies stnull     `shouldBe` False

    it "has sane setters of ambiguous types" $ do
      cookieName        (setCookieName        "a"      stnull) `shouldBe` "a"
      authKey           (setAuthKey           "a"      stnull) `shouldBe` "a"
      idleTimeout       (setIdleTimeout       (Just 1) stnull) `shouldBe` Just 1
      absoluteTimeout   (setAbsoluteTimeout   (Just 1) stnull) `shouldBe` Just 1
      persistentCookies (setPersistentCookies False    stnull) `shouldBe` False
      httpOnlyCookies   (setHttpOnlyCookies   False    stnull) `shouldBe` False
      secureCookies     (setSecureCookies     True     stnull) `shouldBe` True

  describe "loadSession" $ do
    let checkEmptySession (sessionMap, SaveSessionToken msession time) = do
          -- Saved time is close to now, session map is empty,
          -- there's no reference to an existing session.
          let point1 = 0.1 {- second -} :: Double
          now <- TI.getCurrentTime
          abs (realToFrac $ TI.diffUTCTime now time) `shouldSatisfy` (< point1)
          sessionMap `shouldBe` M.empty
          msession `shouldSatisfy` isNothing

    it "returns empty session and token when the session ID cookie is not present" $ do
      ret <- loadSession sttnt Nothing
      checkEmptySession ret

    it "does not need the storage if session ID cookie has invalid data" $ do
      ret <- loadSession sttnt (Just "123456789-123456789-123")
      checkEmptySession ret

    it "returns empty session and token when the session ID cookie refers to inexistent session" $ do
      -- In particular, the save token should *not* refer to the
      -- session ID that was given.  We're a strict session
      -- management system.
      -- <https://www.owasp.org/index.php/Session_Management_Cheat_Sheet#Session_ID_Generation_and_Verification:_Permissive_and_Strict_Session_Management>
      st  <- createState =<< emptyMockStorage
      ret <- loadSession st (Just "123456789-123456789-1234")
      checkEmptySession ret

    it "returns the session from the storage when the session ID refers to an existing session" $ do
      let session = Session
            { sessionKey        = S "123456789-123456789-1234"
            , sessionAuthId     = Just authId
            , sessionData       = M.fromList [("a", "b"), ("c", "d")]
            , sessionCreatedAt  = TI.addUTCTime (-10) fakenow
            , sessionAccessedAt = TI.addUTCTime (-5)  fakenow
            }
          authId = "auth-id"
      st  <- createState =<< prepareMockStorage [session]
      (retSessionMap, SaveSessionToken msession _now) <-
          loadSession st (Just $ B8.pack $ T.unpack $ unS $ sessionKey session)
      retSessionMap `shouldBe` M.insert (authKey st) authId (sessionData session)
      msession      `shouldBe` Just session

  describe "checkExpired" $ do
    prop "agrees with nextExpires" $
      \idleSecs absSecs ->
        let idleDiff  = realToFrac $ max 1 $ abs (idleSecs :: Int)
            absDiff   = realToFrac $ max 1 $ abs (absSecs  :: Int)
            st'       = setIdleTimeout     (Just idleDiff) $
                        setAbsoluteTimeout (Just absDiff) stnull
            sessTimes = do
              diff <- [0, idleDiff, absDiff]
              off <- [1, 0, -1]
              return $ TI.addUTCTime (negate $ diff + off) fakenow
            sessions  = do
              createdAt  <- sessTimes
              accessedAt <- sessTimes
              return $ Session
                { sessionKey        = error "irrelevant 1"
                , sessionAuthId     = error "irrelevant 2"
                , sessionData       = error "irrelevant 3"
                , sessionCreatedAt  = createdAt
                , sessionAccessedAt = accessedAt
                }
            test s =
              Q.counterexample
                (unlines
                   [ "fakenow    = " ++ show fakenow
                   , "createdAt  = " ++ show (sessionCreatedAt s)
                   , "accessedAt = " ++ show (sessionAccessedAt s)
                   , "checkRet   ~ " ++ show (() <$ checkRet)
                   , "nextRet    = " ++ show nextRet ])
                (isJust checkRet == (nextRet >= Just fakenow))
              where checkRet = checkExpired fakenow st' s
                    nextRet  = nextExpires st' s
        in Q.conjoin (test <$> sessions)

  describe "nextExpires" $ do
    it "should have unit tests" pending

  describe "cookieExpires" $ do
    prop "is Nothing for non-persistent cookies regardless of session" $
      \midleSecs mabsSecs ->
        let idleDiff  = realToFrac . max 1 . abs <$> (midleSecs :: Maybe Int)
            absDiff   = realToFrac . max 1 . abs <$> (mabsSecs  :: Maybe Int)
            st'       = setIdleTimeout       idleDiff $
                        setAbsoluteTimeout   absDiff  $
                        setPersistentCookies False stnull
        in cookieExpires st' (error "irrelevant") Q.=== Nothing
    it "is a long time for persistent cookies without timeouts regardless of session" $
      let st' = setIdleTimeout     Nothing $
                setAbsoluteTimeout Nothing stnull
          session = Session
            { sessionKey        = error "irrelevant 1"
            , sessionAuthId     = error "irrelevant 2"
            , sessionData       = error "irrelevant 3"
            , sessionCreatedAt  = error "irrelevant 4"
            , sessionAccessedAt = fakenow
            }
          distantFuture = TI.addUTCTime (60*60*24*365*10) fakenow
      in cookieExpires st' session `shouldSatisfy` maybe False (>= distantFuture)

  describe "saveSession" $ do
    it "should have more tests" pending

  describe "invalidateIfNeeded" $ do
    it "should have more tests" pending

  describe "saveSessionOnDb" $ do
    it "should have more tests" pending

  describe "decomposeSession" $ do
    prop "it is sane when not finding auth key or force invalidate key" $
      \data_ ->
        let sessionMap = mkSessionMap $ filter (notSpecial . fst) $ data_
            notSpecial = flip notElem [authKey stnull, forceInvalidateKey] . T.pack
        in decomposeSession stnull sessionMap `shouldBe`
           DecomposedSession Nothing DoNotForceInvalidate sessionMap

    prop "parses the force invalidate key" $
      \data_  ->
        let sessionMap v = M.insert forceInvalidateKey (B8.pack $ show v) $ mkSessionMap data_
            allForces    = [minBound..maxBound] :: [ForceInvalidate]
            test v       = dsForceInvalidate (decomposeSession stnull $ sessionMap v) Q.=== v
        in Q.conjoin (test <$> allForces)

    it "should have more tests" pending

  describe "toSessionMap" $ do
    let mkSession authId data_ = Session
          { sessionKey        = error "irrelevant 1"
          , sessionAuthId     = authId
          , sessionData       = mkSessionMap data_
          , sessionCreatedAt  = error "irrelevant 2"
          , sessionAccessedAt = error "irrelevant 3"
          }

    prop "does not change session data for sessions without auth ID" $
      \data_ ->
        let s = mkSession Nothing data_
        in toSessionMap stnull s Q.=== sessionData s

    prop "adds (overwriting) the auth ID to the session data" $
      \authId_ data_ ->
        let s = mkSession (Just authId) ((T.unpack k, "foo") : data_)
            k = authKey stnull
            authId = B8.pack authId_
        in toSessionMap stnull s Q.=== M.adjust (const authId) k (sessionData s)

  describe "MockStorage" $ do
    sto <- runIO emptyMockStorage
    parallel $ allStorageTests sto it runIO shouldBe shouldReturn shouldThrow


-- | Used to generate session maps on QuickCheck properties.
mkSessionMap :: [(String, String)] -> SessionMap
mkSessionMap = M.fromList . map (T.pack *** B8.pack)


----------------------------------------------------------------------


-- | A storage that explodes if it's used.  Useful for checking
-- that the storage is irrelevant on a code path.
data TNTStorage = TNTStorage deriving (Typeable)

instance Storage TNTStorage where
  type TransactionM TNTStorage = IO
  runTransactionM _         = id
  getSession                = explode "getSession"
  deleteSession             = explode "deleteSession"
  deleteAllSessionsOfAuthId = explode "deleteAllSessionsOfAuthId"
  insertSession             = explode "insertSession"
  replaceSession            = explode "replaceSession"


-- | Implementation of all 'Storage' methods of 'TNTStorage'
-- (except for runTransactionM).
explode :: Show a => String -> TNTStorage -> a -> TransactionM TNTStorage b
explode fun _ = E.throwIO . TNTExplosion fun . show


-- | Exception thrown by 'explode'.
data TNTExplosion = TNTExplosion String String deriving (Show, Typeable)

instance E.Exception TNTExplosion where


----------------------------------------------------------------------


-- | A mock storage used just for testing.
data MockStorage =
  MockStorage
    { mockSessions :: I.IORef (M.Map SessionId Session)
    }
  deriving (Typeable)

instance Storage MockStorage where
  type TransactionM MockStorage = IO
  runTransactionM _ = id
  getSession sto sid =
    -- We need to use atomicModifyIORef instead of readIORef
    -- because latter may be reordered (cf. "Memory Model" on
    -- Data.IORef's documentation).
    M.lookup sid <$> I.atomicModifyIORef' (mockSessions sto) (\a -> (a, a))
  deleteSession sto sid =
    I.atomicModifyIORef' (mockSessions sto) ((, ()) . M.delete sid)
  deleteAllSessionsOfAuthId sto authId =
    I.atomicModifyIORef' (mockSessions sto) ((, ()) . M.filter (\s -> sessionAuthId s /= Just authId))
  insertSession sto session =
    join $ I.atomicModifyIORef' (mockSessions sto) $ \oldMap ->
      let (moldVal, newMap) =
            M.insertLookupWithKey (\_ v _ -> v) (sessionKey session) session oldMap
      in maybe
           (newMap, return ())
           (\oldVal -> (oldMap, E.throwIO $ SessionAlreadyExists oldVal session))
           moldVal
  replaceSession sto session =
    join $ I.atomicModifyIORef' (mockSessions sto) $ \oldMap ->
      let (moldVal, newMap) =
            M.insertLookupWithKey (\_ v _ -> v) (sessionKey session) session oldMap
      in maybe
           (oldMap, E.throwIO $ SessionDoesNotExist session)
           (const (newMap, return ()))
           moldVal


-- | Creates empty mock storage.
emptyMockStorage :: IO MockStorage
emptyMockStorage =
  MockStorage
    <$> I.newIORef M.empty


-- | Creates mock storage with the given sessions already existing.
prepareMockStorage :: [Session] -> IO MockStorage
prepareMockStorage sessions = do
  sto <- emptyMockStorage
  I.writeIORef (mockSessions sto) (M.fromList [(sessionKey s, s) | s <- sessions])
  return sto
