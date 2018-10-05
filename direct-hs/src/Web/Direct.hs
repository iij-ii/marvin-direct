-- | Client library for Direct.
module Web.Direct
    (
  -- * Configuration
      Config(..)
    , defaultConfig
    , URL
  -- * Login
    , login
  -- ** Login information
    , LoginInfo(..)
    , serializeLoginInfo
    , deserializeLoginInfo
  -- * Client
    , Client
    , withClient
    , getDomains
    , getTalkRooms
    , getMe
    , getUsers
  -- * Message
  -- ** Ids
    , DomainId
    , TalkId
    , UserId
    , MessageId
  -- ** Abstract types
  -- *** Domain
    , Domain
    , domainId
    , domainName
  -- *** Talk room
    , TalkRoom
    , talkId
    , talkUsers
    , talkType
    , TalkType(..)
  -- *** User
    , User
    , userId
    , displayName
    , canonicalDisplayName
    , phoneticDisplayName
    , canonicalPhoneticDisplayName
  -- ** Message
    , Message(..)
  -- * Sending
    , sendMessage
  -- * Channel
  -- ** Channel type
    , ChannelType
    , pairChannel
    , pinPointChannel
    , groupChannel
  -- ** Creating channel
    , Channel
    , withChannel
    , channelTalkRoom
  -- ** Channel IO
    , recv
    , send
  -- * Terminating
    , shutdown
  -- *Exceptions
    , Exception(..)
    )
where

import           Web.Direct.Api
import           Web.Direct.Client
import           Web.Direct.Exception
import           Web.Direct.LoginInfo
import           Web.Direct.Message
import           Web.Direct.Types

import           Web.Direct.DirectRPC hiding (getDomains)

createPair :: Client -> User -> IO TalkRoom
createPair client = createPairTalk (clientRpcClient client)
