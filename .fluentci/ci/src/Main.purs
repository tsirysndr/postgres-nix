module Main (check, prepare) where

import Prelude
import CI.Nix as Nix
import CI.Setup as Setup
import Data.Maybe (Maybe)
import Data.Either (either)
import Effect (Effect)
import Effect.Exception (throw)

-- | Install Nix, build PostgreSQL and pgstream, run restore checks and report every executable.
-- | @param system Expected native Nix platform; omit to use the current platform.
check :: { system :: Maybe String } -> Effect Unit
check args = do
  environment <- Setup.installNix
  Nix.checkWith environment args

-- | Test the PureScript CI module and stage its fully composed portable Wasm artifact without building Nix packages.
prepare :: Effect Unit
prepare = do
  Nix.run "test-ci-module" [ "npm", "--prefix", ".fluentci/ci", "test" ]
  Nix.verifyHost
  discovery <- Nix.capture "compose-ci-module" [ "fluentci", "--check-update=false", "modules", "ci", "--json" ]
  artifact <- either throw pure (Nix.parseArtifact discovery)
  Nix.run "stage-ci-component" [ "cp", artifact, ".fluentci/ci/dist/ci.wasm" ]
