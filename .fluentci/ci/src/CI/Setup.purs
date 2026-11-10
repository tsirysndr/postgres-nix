module CI.Setup (installNix) where

import Prelude
import CI.Nix (capture)
import Data.String.Common (trim)
import Effect (Effect)

-- The FFI only binds the dependency's native typed component interface.
foreign import setupNix :: { sudo :: Boolean, trustedUsers :: Array String } -> Effect Unit

installNix :: Effect Unit
installNix = do
  user <- trim <$> capture "runner-user" [ "id", "-un" ]
  setupNix { sudo: true, trustedUsers: [ user ] }
