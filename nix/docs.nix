# The documentation site at https://calebstew.art/claude-code.nvim.
#
# `nix build .#docs` and the Pages workflow realize the same derivation, so
# what deploys cannot drift from what you preview.
{
  lib,
  stdenvNoCC,
  cacert,
  zola,
}:
stdenvNoCC.mkDerivation {
  pname = "claude-code-nvim-docs";

  # Deliberately not the flake's `version`, which embeds the git rev and so
  # changes on every commit: threading it in here would rebuild the site for a
  # plugin-only change. This derivation's hash depends on docs/ and zola, and
  # nothing else.
  version = "0.1.0";

  # Only docs/. The site does not depend on the plugin, and `zola build` would
  # otherwise see dist/, sidecar/node_modules and the rest of the checkout in
  # its source.
  src = lib.fileset.toSource {
    root = ../docs;
    fileset = lib.fileset.unions [
      ../docs/config.toml
      ../docs/content
      ../docs/static
      ../docs/templates
    ];
  };

  nativeBuildInputs = [ zola ];

  # Zola builds an HTTP client up front for `load_data`, and panics if it cannot
  # load any CA certificates -- which a sandboxed build has none of. This site
  # fetches nothing; the certificates are only there so the client constructs.
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  buildPhase = ''
    runHook preBuild
    zola build --output-dir ./public
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r ./public $out
    runHook postInstall
  '';

  meta = {
    description = "Documentation site for claude-code.nvim";
    homepage = "https://calebstew.art/claude-code.nvim";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
