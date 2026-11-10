{ pkgs }:
let
  assets = {
    x86_64-linux = { name = "linux.amd64"; sha256 = "e86ccd704f7d99a0794a75a6c1d1095d30c8bc8c21a22b793914db8340bad182"; };
    aarch64-linux = { name = "linux.arm64"; sha256 = "c37f41f29b8e5784a47f91069975bd397448cf1014d47cd426680f18a84804a7"; };
    x86_64-darwin = { name = "macos.amd64"; sha256 = "06569f896f9e489968779485dd4000027ecce3dde63f24a0fca2ac3317df29af"; };
    aarch64-darwin = { name = "macos.arm64"; sha256 = "43dfe63f05c74b98a83077bea466238371ad0a245e4081d30ed78760227cd8b4"; };
  };
  asset = assets.${pkgs.stdenv.hostPlatform.system};
in pkgs.stdenvNoCC.mkDerivation rec {
  pname = "pgroll";
  version = "0.16.3";
  src = pkgs.fetchurl {
    url = "https://github.com/xataio/pgroll/releases/download/v${version}/pgroll.${asset.name}";
    inherit (asset) sha256;
  };
  dontUnpack = true;
  # Upstream links Linux binaries statically. Preserve the Darwin binaries unchanged.
  dontFixup = true;
  installPhase = ''
    runHook preInstall
    install -Dm755 "$src" "$out/bin/pgroll"
    runHook postInstall
  '';
  meta = {
    description = "PostgreSQL zero-downtime reversible schema migrations";
    homepage = "https://github.com/xataio/pgroll";
    license = pkgs.lib.licenses.asl20;
    platforms = builtins.attrNames assets;
    mainProgram = "pgroll";
    sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
  };
}
