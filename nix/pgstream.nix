{ pkgs }:
let
  assets = {
    x86_64-linux = { name = "linux.amd64"; sha256 = "f9da5d0c299139db5236b63bdbd5cc20f6e1267db989c51d6444f429150c158b"; };
    aarch64-linux = { name = "linux.arm64"; sha256 = "cd4cca3a4b6bd705a762bfdfcd1ac99c01189ec39048d607854e1068df40f969"; };
    x86_64-darwin = { name = "macos.amd64"; sha256 = "cb5da31b82d383db46ab0d2e160a04db4e9cff60ee81ccc884ee94e6d32a6868"; };
    aarch64-darwin = { name = "macos.arm64"; sha256 = "8fe840c9923a12b713b8574303bafcfe52c5ad05dcd15960c633b7e34cb99073"; };
  };
  asset = assets.${pkgs.stdenv.hostPlatform.system};
in pkgs.stdenvNoCC.mkDerivation rec {
  pname = "pgstream";
  version = "1.6.0";
  src = pkgs.fetchurl {
    url = "https://github.com/xataio/pgstream/releases/download/v${version}/pgstream.${asset.name}";
    inherit (asset) sha256;
  };
  dontUnpack = true;
  # Upstream uses CGO_ENABLED=0. Preserve the original Darwin code signature.
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/pgstream"
    runHook postInstall
  '';
  meta = {
    description = "PostgreSQL change data capture with DDL replication";
    homepage = "https://github.com/xataio/pgstream";
    license = pkgs.lib.licenses.asl20;
    platforms = builtins.attrNames assets;
    mainProgram = "pgstream";
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
