{
  lib,
  php,
  ...
}:
let
  # Parse the Admidio version out of system/bootstrap/constants.php so the
  # derivation can never disagree with the shipped code (the same string the
  # Docker image writes into .admidio_image_version).
  versionFile = builtins.readFile ../system/bootstrap/constants.php;

  readVersionConstant =
    name:
    let
      match = builtins.match ".*const ${name} = ([0-9]+);.*" versionFile;
    in
    if match == null then
      throw "package.nix: cannot find constant ${name} in system/bootstrap/constants.php"
    else
      builtins.head match;

  versionMain = readVersionConstant "ADMIDIO_VERSION_MAIN";
  versionMinor = readVersionConstant "ADMIDIO_VERSION_MINOR";
  versionPatch = readVersionConstant "ADMIDIO_VERSION_PATCH";
  versionBeta = readVersionConstant "ADMIDIO_VERSION_BETA";

  version =
    "${versionMain}.${versionMinor}.${versionPatch}"
    + lib.optionalString (versionBeta != "0") "-beta.${versionBeta}";

  # Runtime PHP with the extensions of the official Docker image
  # (bcmath, bz2, curl, gd, gmp, imagick, intl, ldap, mbstring, mysql,
  # pgsql, soap, tidy, xml, zip) and the PHP extensions the application
  # and its dependencies require (ext-ctype, ext-dom, ext-fileinfo,
  # ext-filter, ext-openssl, ext-session, ext-tokenizer, ext-xmlreader,
  # ext-zlib, ...). igbinary, uploadprogress and xmlrpc are not available
  # in nixpkgs and are not required by Admidio. The PHP version is the one
  # passed in by the caller; the flake uses php83 to match the Docker image.
  phpRuntime = php.buildEnv {
    extensions =
      { all, ... }:
      with all;
      [
        bcmath
        bz2
        ctype
        curl
        dom
        exif
        fileinfo
        filter
        gd
        gmp
        iconv
        imagick
        intl
        ldap
        mbstring
        openssl
        pdo_mysql
        pdo_pgsql
        posix
        session
        simplexml
        soap
        sodium
        tidy
        tokenizer
        xmlreader
        xmlwriter
        zlib
        zip
      ];
  };

  appRoot = "${placeholder "out"}/share/php/admidio";

  # Development, CI and Nix files that are not part of the shipped web
  # application (mirrors .dockerignore plus the packaging files). The
  # application is built as "everything except this list", so new upstream
  # files are shipped without touching the package. maybeMissing tolerates
  # paths that are not present in the flake source (such as .git).
  excludedPaths = [
    ../.codeclimate.yml
    ../.dockerignore
    ../.editorconfig
    ../.env.test.example
    ../.git
    ../.gitattributes
    ../.github
    ../.gitignore
    ../.php-cs-fixer.dist.php
    ../.travis.yml
    ../Dockerfile
    ../README-Docker.md
    ../demo_data
    ../docker-compose.test.yml
    ../dockerscripts
    ../flake.lock
    ../flake.nix
    ../hooks
    ../nix
    ../nixos
    ../phpunit.xml
    ../result
    ../tests
  ];
in
php.buildComposerProject2 (finalAttrs: {
  pname = "admidio";
  inherit version;

  # ship the whole checkout minus the development files; lib.fileset computes
  # the difference lazily, so excluded trees (notably .git) are never walked.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.difference (lib.fileset.unions [ ../. ]) (
      lib.fileset.unions (map lib.fileset.maybeMissing excludedPaths)
    );
  };

  vendorHash = "sha256-KsrnNltvjLsJpLD7z6VNCGnM/YQMAn4vsBJocU5PzyQ=";

  # The application has no checks that could run without a database.
  doCheck = false;
  doInstallCheck = false;

  # The app root stays at $out/share/php/admidio (upstream layout: Admidio
  # derives its paths from its own file locations, so the NixOS module
  # provisions this tree into /var/lib and serves that copy with nginx).
  postInstall = ''
    echo -n "${finalAttrs.version}" > ${appRoot}/.admidio_image_version
  '';

  passthru = {
    php = phpRuntime;
    # The application root inside the derivation.
    appRoot = "/share/php/admidio";
  };

  meta = {
    description = "Free open source user management system for websites of organizations and groups";
    homepage = "https://www.admidio.org/";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.all;
  };
})
