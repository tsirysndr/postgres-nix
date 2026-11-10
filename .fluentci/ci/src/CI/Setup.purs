module CI.Setup (installNix) where

import Prelude
import CI.Nix (capture)
import Data.String.Common (trim)
import Effect (Effect)

-- The FFI only binds the dependency's native typed component interface.
foreign import setupNix :: { sudo :: Boolean, trustedUsers :: Array String } -> Effect
  { tool :: String, version :: String, binDir :: String, environment :: Array { name :: String, value :: String } }

installNix :: Effect (Array { name :: String, value :: String })
installNix = do
  user <- trim <$> capture "runner-user" [ "id", "-un" ]
  installed <- setupNix { sudo: true, trustedUsers: [ user ] }
  pure installed.environment
