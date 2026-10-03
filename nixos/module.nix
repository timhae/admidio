/*
  NixOS module for Admidio, a free open source user management system for
  websites of organizations and groups.

  The module provisions the PHP application from the derivation into
  /var/lib/admidio (the same layout the official Docker image uses) because
  Admidio needs its writable data directory adm_my_files/ inside its
  application root. nginx serves static files from that directory and passes
  PHP requests to a php-fpm pool, which replaces the Apache + mod-php setup
  of the Docker image.
*/
{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.admidio;

  pool = "admidio";
  fpm = config.services.phpfpm.pools.${pool};
  phpExecutionUnit = "phpfpm-${pool}.service";

  inherit (cfg) user group dataDir;

  # The application root inside the derivation.
  appRoot = "${cfg.package}${cfg.package.appRoot or "/share/php/admidio"}";

  # PHP with the extensions of the official Docker image, used by php-fpm,
  # the provisioning service and the command line interface.
  php = cfg.package.php;

  # The module manages adm_my_files/config.php if all database values are
  # known from the configuration (the same cases in which the official
  # Docker image generates config.php from its environment variables).
  dbManaged = cfg.database.createLocally || cfg.database.passwordFile != null;

  tlsEnabled =
    cfg.nginx != null
    && (cfg.nginx.addSSL || cfg.nginx.forceSSL || cfg.nginx.onlySSL || cfg.nginx.enableACME);

  rootUrl =
    if cfg.rootUrl != null then
      cfg.rootUrl
    else
      "${if tlsEnabled then "https" else "http"}://${cfg.hostname}";

  # Path of the MySQL unix socket, used for connections to a local
  # MySQL/MariaDB through database.host = "localhost".
  dbSocket =
    if cfg.database.socket != null then
      cfg.database.socket
    else if
      cfg.database.createLocally
      && elem cfg.database.type [
        "mysql"
        "mariadb"
      ]
    then
      "/run/mysqld/mysqld.sock"
    else
      null;

  # Host the module connects to for a locally created database: the MySQL
  # unix socket through "localhost" (see dbSocket) or the PostgreSQL socket
  # directory, in which peer authentication identifies the database user
  # with the system user.
  localDbHost = if cfg.database.type == "pgsql" then "/run/postgresql" else "localhost";

  # Admidio 5.0 only knows the PDO engines "mysql" and "pgsql"; MariaDB is
  # reached through the MySQL engine. The module keeps "mariadb" as a
  # separate option because it selects the MariaDB server package.
  dbEngine = if cfg.database.type == "mariadb" then "mysql" else cfg.database.type;

  # The unit the recurring maintenance job needs for a locally created
  # database. postgresql.target includes postgresql-setup.service, which
  # creates the database and the user.
  databaseService =
    if !cfg.database.createLocally then
      null
    else if cfg.database.type == "pgsql" then
      "postgresql.target"
    else
      "mysql.service";

  # Email of the initially created organization. The installation requires one,
  # so it falls back to the email of the administrator.
  organizationEmail =
    if cfg.installation.organization.email != null then
      cfg.installation.organization.email
    else
      cfg.installation.admin.email;

  # Generates adm_my_files/config.php at runtime, so the database password
  # never becomes part of the Nix store.
  configGen = pkgs.writeText "admidio-config-gen.php" (builtins.readFile ./config-gen.php);

  # Admidio 5.0 has no command line administration utility. This helper
  # provides the non-interactive installation and the recurring maintenance
  # jobs on top of the same code the web interface uses.
  cliScript = pkgs.writeText "admidio-cli.php" (builtins.readFile ./cli.php);

  genConfigCmd = optionalString dbManaged ''
    ${php}/bin/php ${configGen} \
      --out=adm_my_files/config.php \
      --db-type='${dbEngine}' \
      --table-prefix='${cfg.database.tablePrefix}' \
      --db-host='${cfg.database.host}' \
      ${optionalString (cfg.database.port != null) "--db-port='${toString cfg.database.port}'"} \
      --db-name='${cfg.database.name}' \
      --db-user='${cfg.database.user}' \
      ${
        optionalString (
          cfg.database.passwordFile != null
        ) "--password-file=''${CREDENTIALS_DIRECTORY}/dbpass"
      } \
      --root-url='${rootUrl}' \
      --timezone='${cfg.timezone}' \
      --login-for-update=${if cfg.loginForUpdate then "1" else "0"} \
      --password-hash-algorithm='${cfg.passwordHashAlgorithm}' \
      --debug=${if cfg.debug then "1" else "0"}
  '';

  cliSocketFlag = optionalString (dbSocket != null) "-d pdo_mysql.default_socket=${dbSocket}";

  # The Admidio command line administration utility, run against the
  # provisioned application and as the service user (installation and
  # maintenance).
  admidioCli = pkgs.writeShellApplication {
    name = "admidio";
    text = ''
      if [ "$(id -un)" != ${user} ]; then
        exec /run/wrappers/bin/sudo -u ${user} "$0" "$@"
      fi
      cd ${dataDir}
      exec ${php}/bin/php ${cliSocketFlag} ${cliScript} "$@"
    '';
    meta = {
      description = "Admidio command line administration utility";
      mainProgram = "admidio";
    };
  };
in
{
  options = {
    services.admidio = {
      enable = mkEnableOption "Admidio, a free open source user management system for websites of organizations and groups";

      package = mkPackageOption pkgs "admidio" { };

      user = mkOption {
        type = types.str;
        default = "admidio";
        description = ''
          User under which Admidio runs. The user (and
          {option}`services.admidio.group`) is created by this module as a
          system account.
        '';
      };

      group = mkOption {
        type = types.str;
        default = "admidio";
        description = "Group under which Admidio runs. The group is created by this module.";
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/admidio";
        description = ''
          The application and data directory of Admidio. The PHP application
          is provisioned into this directory because Admidio keeps its writable
          data directory `adm_my_files` inside its application root. It is
          served by nginx.
        '';
      };

      hostname = mkOption {
        type = types.str;
        default = "admidio.${config.networking.fqdnOrHostName}";
        defaultText = literalExpression "admidio.''${config.networking.fqdnOrHostName}";
        example = "admidio.example.org";
        description = "The hostname (without scheme) of the nginx virtual host for Admidio.";
      };

      nginx = mkOption {
        type = types.nullOr (
          types.submodule (
            recursiveUpdate
              (import "${pkgs.path}/nixos/modules/services/web-servers/nginx/vhost-options.nix" {
                inherit config lib;
              })
              {
                # enable encryption by default, as sensitive login and
                # organization data should not be transmitted in clear text.
                options.forceSSL.default = true;
                options.enableACME.default = true;
              }
          )
        );
        default = null;
        example = literalExpression ''
          {
            forceSSL = false;
            enableACME = false;
            serverAliases = [ "members.''${config.networking.domain}" ];
          }
        '';
        description = ''
          With this option, you can customize an nginx virtualHost which
          already has sensible defaults for Admidio. Set it to `{}` to just
          enable the virtual host if you don't need any customization.
          If it is null (the default), no nginx virtual host is configured
          and this module cannot be used.
        '';
      };

      database = {
        type = mkOption {
          type = types.enum [
            "mariadb"
            "mysql"
            "pgsql"
          ];
          default = "mariadb";
          description = "Type of the database Admidio stores its data in.";
        };

        host = mkOption {
          type = types.str;
          default =
            if cfg.database.createLocally && cfg.database.type == "pgsql" then
              "/run/postgresql"
            else
              "localhost";
          defaultText = literalExpression "localhost";
          example = "db.example.org";
          description = ''
            Host of the database server. A value of `localhost` (the default)
            connects through the unix socket for MySQL/MariaDB. For a locally
            created PostgreSQL database the default is the socket directory
            `/run/postgresql` instead.
          '';
        };

        port = mkOption {
          type = types.nullOr types.port;
          default = null;
          description = "Port of the database server. The default port of the database system is used if null.";
        };

        name = mkOption {
          type = types.str;
          default = "admidio";
          description = "Name of the database that holds the Admidio data.";
        };

        user = mkOption {
          type = types.str;
          default = "admidio";
          description = "The database user that Admidio uses to connect.";
        };

        passwordFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "/run/keys/admidio-dbpassword";
          description = ''
            A file containing the database password. If set, the module
            generates `adm_my_files/config.php` from the
            {option}`services.admidio.database.*` options on every restart of
            the provisioning service, overwriting an existing configuration
            file. Keep it null (the default) to leave `config.php` untouched,
            in which case you create it with the web or command line
            installation wizard.
          '';
        };

        tablePrefix = mkOption {
          type = types.str;
          default = "adm";
          description = "Table prefix for the Admidio tables in the database.";
        };

        socket = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/mysqld/mysqld.sock";
          description = ''
            Path of the MySQL unix socket used for connections to
            `localhost`. Defaults to the socket of the locally created
            database if {option}`services.admidio.database.createLocally`
            is enabled.
          '';
        };

        createLocally = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Create the database and a database user with socket/peer
            authentication locally, MariaDB (the default) or PostgreSQL. The
            database user must be the {option}`services.admidio.user` in that
            case, for PostgreSQL the database name must be equal to the
            database user, and
            {option}`services.admidio.database.passwordFile` must be null.
            The module generates `adm_my_files/config.php` accordingly.
          '';
        };
      };

      rootUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "https://members.example.org/admidio";
        description = ''
          The complete URL of this Admidio installation
          (`$g_root_path`). Derived from
          {option}`services.admidio.hostname` if null.
        '';
      };

      timezone = mkOption {
        type = types.str;
        default = if config.time.timeZone != null then config.time.timeZone else "UTC";
        defaultText = literalExpression "config.time.timeZone or \"UTC\"";
        example = "Europe/Berlin";
        description = "The name of the timezone in which your organization is located (`$gTimezone`).";
      };

      loginForUpdate = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Require login name and password for an update of the Admidio
          database to a new version of Admidio (`$gLoginForUpdate`).
        '';
      };

      passwordHashAlgorithm = mkOption {
        type = types.enum [
          "DEFAULT"
          "ARGON2ID"
          "ARGON2I"
          "BCRYPT"
          "SHA512"
        ];
        default = "DEFAULT";
        description = "The preferred password hashing algorithm (`$gPasswordHashAlgorithm`).";
      };

      debug = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Show PHP errors and the executed SQL statements of Admidio
          (`$gDebug`).
        '';
      };

      maxUploadSize = mkOption {
        type = types.str;
        default = "16M";
        example = "1G";
        description = "The maximum size of files uploaded to Admidio, e.g. photos or documents.";
      };

      maintenance = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Periodically run the Admidio maintenance jobs (category
            reorganization and document path repair). This replaces the cron
            job of the official Docker image.
          '';
        };

        startAt = mkOption {
          type = types.str;
          default = "daily";
          example = "*-*-* 03:00:00";
          description = "When to run the Admidio maintenance jobs.";
        };
      };

      installation = {
        enable = mkEnableOption ''
          automatic installation of the Admidio database with an initial
          organization and administrator. The installation runs once, after the
          application and the database have been provisioned
        '';

        language = mkOption {
          type = types.str;
          default = "en";
          example = "de";
          description = "Language of the initially created organization.";
        };

        organization = {
          shortName = mkOption {
            type = types.str;
            default = "default";
            example = "EXAMPLE";
            description = "Short name of the initially created organization.";
          };

          name = mkOption {
            type = types.str;
            default = "default";
            example = "Example Organization";
            description = "Name of the initially created organization.";
          };

          email = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "info@example.org";
            description = ''
              Email address of the initially created organization. Defaults to
              {option}`services.admidio.installation.admin.email` if null.
            '';
          };
        };

        admin = {
          login = mkOption {
            type = types.str;
            default = "admin";
            example = "tim";
            description = "Login name of the administrator created by the installation.";
          };

          firstName = mkOption {
            type = types.str;
            default = "Admin";
            description = "First name of the administrator created by the installation.";
          };

          lastName = mkOption {
            type = types.str;
            default = "Admin";
            description = "Last name of the administrator created by the installation.";
          };

          email = mkOption {
            type = types.str;
            default = "";
            example = "admin@example.org";
            description = "Email address of the administrator created by the installation.";
          };

          passwordFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/run/keys/admidio-admin-password";
            description = ''
              A file containing the password of the administrator created by
              the installation. The password must have at least 8 characters
              and pass the strength check of Admidio, otherwise the
              installation fails. It is read through systemd credentials and
              never becomes part of the Nix store.
            '';
          };
        };
      };

      poolConfig = mkOption {
        type =
          with types;
          attrsOf (oneOf [
            str
            int
            bool
          ]);
        default = { };
        example = literalExpression ''
          {
            "pm" = "static";
            "pm.max_children" = 50;
          }
        '';
        description = "Options for the Admidio php-fpm pool.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nginx != null;
        message = "services.admidio.nginx must be set (e.g. to {}) because this module serves Admidio with nginx.";
      }
      {
        assertion = !cfg.database.createLocally || cfg.database.passwordFile == null;
        message = "services.admidio.database.passwordFile must be null if services.admidio.database.createLocally is enabled (the local database user authenticates through the socket).";
      }
      {
        assertion = !cfg.database.createLocally || cfg.database.user == cfg.user;
        message = "services.admidio.database.user must be set to ${cfg.user} if services.admidio.database.createLocally is enabled (the local database user authenticates as that system user).";
      }
      {
        assertion = !cfg.database.createLocally || cfg.database.host == localDbHost;
        message = "services.admidio.database.host must stay ${localDbHost} if services.admidio.database.createLocally is enabled (the local database is reached through it).";
      }
      {
        assertion =
          !cfg.database.createLocally
          || elem cfg.database.type [
            "mysql"
            "mariadb"
            "pgsql"
          ];
        message = "services.admidio.database.createLocally only supports mysql, mariadb or pgsql.";
      }
      {
        assertion =
          !cfg.database.createLocally
          || cfg.database.type != "pgsql"
          || cfg.database.name == cfg.database.user;
        message = "services.admidio.database.name must be set to the name of the database user for a locally created PostgreSQL database (the user gets the ownership of the database).";
      }
      {
        assertion = cfg.database.passwordFile == null || hasPrefix "/" cfg.database.passwordFile;
        message = "services.admidio.database.passwordFile must be an absolute path.";
      }
      {
        assertion = !cfg.installation.enable || dbManaged;
        message = "services.admidio.installation requires that the module manages the database: enable services.admidio.database.createLocally or set services.admidio.database.passwordFile.";
      }
      {
        assertion = !cfg.installation.enable || cfg.installation.admin.email != "";
        message = "services.admidio.installation.admin.email must be set when services.admidio.installation.enable is enabled.";
      }
      {
        assertion = !cfg.installation.enable || cfg.installation.admin.passwordFile != null;
        message = "services.admidio.installation.admin.passwordFile must be set when services.admidio.installation.enable is enabled (the installation runs non-interactively).";
      }
    ];

    # The service account is created by the module. mkDefault keeps the values
    # overridable in case the user or group is defined elsewhere as well.
    users.users.${user} = {
      isSystemUser = mkDefault true;
      group = mkDefault group;
      home = mkDefault dataDir;
    };
    users.groups.${group} = { };

    systemd.tmpfiles.rules = [
      "d ${dataDir} 0755 ${user} ${group} - -"
      "d ${dataDir}/adm_my_files 0750 ${user} ${group} - -"
    ];

    # Create the local database, the way the snipe-it and nextcloud modules
    # do it. Both database users authenticate as the system user of the
    # service through the unix socket.
    services.mysql =
      mkIf
        (
          cfg.database.createLocally
          && elem cfg.database.type [
            "mysql"
            "mariadb"
          ]
        )
        {
          enable = mkDefault true;
          package = mkDefault pkgs.mariadb;
          ensureDatabases = [ cfg.database.name ];
          ensureUsers = [
            {
              name = cfg.database.user;
              ensurePermissions."${cfg.database.name}.*" = "ALL PRIVILEGES";
            }
          ];
        };

    services.postgresql = mkIf (cfg.database.createLocally && cfg.database.type == "pgsql") {
      enable = mkDefault true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    # Everything the application needs has to be provisioned and kept up to
    # date before Admidio PHP files are executed.
    systemd.services.admidio-provision = {
      description = "Provision the Admidio application into ${dataDir}";
      # the provisioned files are needed by php-fpm (hard) and nginx (soft)
      requiredBy = [ phpExecutionUnit ];
      before = [
        phpExecutionUnit
        "nginx.service"
      ];
      wantedBy = [ "nginx.service" ];
      # run again whenever the package changes
      restartTriggers = [ cfg.package ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = group;
        UMask = "0022";
        WorkingDirectory = dataDir;
      }
      // (optionalAttrs (cfg.database.passwordFile != null) {
        LoadCredential = "dbpass:${cfg.database.passwordFile}";
      });

      script = ''
        set -euo pipefail

        mkdir -p adm_my_files

        installedVersion=""
        if [ -f adm_my_files/.admidio_installed_version ]; then
            installedVersion="$(cat adm_my_files/.admidio_installed_version)"
        fi

        # The package store path changes with every rebuild, the version only
        # with a release. A development build that keeps the version has to
        # reach the data directory too, otherwise the running application stays
        # the old one and code changes appear to have no effect. The service is
        # already restarted through restartTriggers when the package changes;
        # this marker makes the script act on that restart.
        installedPackage=""
        if [ -f adm_my_files/.admidio_installed_package ]; then
            installedPackage="$(cat adm_my_files/.admidio_installed_package)"
        fi

        if [ "$installedVersion" != "${cfg.package.version}" ] || [ "$installedPackage" != "${cfg.package}" ]; then
            echo "[admidio-provision] provisioning application files ''${installedVersion:-<new>} -> ${cfg.package.version}"

            # Application code and top level files: an exact copy of the
            # package. The user-maintained trees are excluded so --delete
            # cannot remove their content. --no-perms: the files in the Nix
            # store are read-only, the permissions of the data directory are
            # set by this script below.
            ${pkgs.rsync}/bin/rsync -a --delete --no-perms \
                --exclude='/adm_my_files/' \
                --exclude='/adm_plugins/' \
                --exclude='/themes/' \
                '${appRoot}/' ./

            # User data: new upstream default files are added, everything the
            # installation created stays (the same excludes as the official
            # Docker image). --ignore-existing keeps a file the administrator
            # edited (e.g. a mail template) instead of overwriting it with the
            # shipped default on every provisioning.
            ${pkgs.rsync}/bin/rsync -a --no-perms --ignore-existing \
                --exclude='/config.php' \
                --exclude='/.admidio_installed' \
                --exclude='/.admidio_installed_version' \
                --exclude='/.admidio_installed_package' \
                '${appRoot}/adm_my_files/' adm_my_files/

            # User-extensible trees: merge without delete.
            ${pkgs.rsync}/bin/rsync -a --no-perms '${appRoot}/adm_plugins/' adm_plugins/
            ${pkgs.rsync}/bin/rsync -a --no-perms '${appRoot}/themes/' themes/
            # the shipped theme follows the code version exactly
            ${pkgs.rsync}/bin/rsync -a --delete --no-perms '${appRoot}/themes/simple/' themes/simple/

            # nginx serves the static files of the application tree, php-fpm
            # runs as the service user, the data stays private to it.
            chmod -R u+rwX,go+rX ./
            chmod -R u+rwX,go-rwx adm_my_files
        fi

        echo -n "${cfg.package.version}" > adm_my_files/.admidio_installed_version
        echo -n "${cfg.package}" > adm_my_files/.admidio_installed_package

        ${genConfigCmd}
      '';
    };

    # Install the database with its first organization and administrator, the
    # same values the web installation wizard would ask for. The service is a
    # no-op once the installation exists, which a marker file records.
    systemd.services.admidio-install = mkIf cfg.installation.enable {
      description = "Install the Admidio organization and administrator";
      requires = [ "admidio-provision.service" ] ++ optional (databaseService != null) databaseService;
      after = [ "admidio-provision.service" ] ++ optional (databaseService != null) databaseService;
      before = [
        phpExecutionUnit
        "nginx.service"
      ];
      wants = optional (databaseService != null) databaseService;
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = user;
        Group = group;
        WorkingDirectory = dataDir;
        LoadCredential = "adminpass:${cfg.installation.admin.passwordFile}";
      };

      script = ''
        set -euo pipefail

        # install:run is not idempotent, so the marker keeps this service from
        # installing a second time. The file lives in the data directory, which
        # re-provisioning never deletes.
        if [ -f adm_my_files/.admidio_installed ]; then
            echo "[admidio-install] Admidio is already installed, nothing to do"
            exit 0
        fi

        echo "[admidio-install] installing Admidio for the organization '${cfg.installation.organization.shortName}'"
        ${php}/bin/php ${cliSocketFlag} ${cliScript} install:run \
            --yes --no-interaction \
            --language='${cfg.installation.language}' \
            --organization-shortname='${cfg.installation.organization.shortName}' \
            --organization-name='${cfg.installation.organization.name}' \
            --organization-email='${organizationEmail}' \
            --admin-login='${cfg.installation.admin.login}' \
            --admin-first-name='${cfg.installation.admin.firstName}' \
            --admin-last-name='${cfg.installation.admin.lastName}' \
            --admin-email='${cfg.installation.admin.email}' \
            --admin-password-stdin \
            < "$CREDENTIALS_DIRECTORY/adminpass"

        touch adm_my_files/.admidio_installed
      '';
    };

    services.phpfpm.pools.${pool} = {
      inherit user group;
      phpPackage = php;
      phpOptions = ''
        upload_max_filesize = ${cfg.maxUploadSize}
        post_max_size = ${cfg.maxUploadSize}
        date.timezone = ${cfg.timezone}
        ${optionalString (dbSocket != null) "pdo_mysql.default_socket = ${dbSocket}"}
      '';
      settings = {
        "listen.owner" = config.services.nginx.user;
        "listen.group" = "root";
        "listen.mode" = "0660";
        "pm" = "dynamic";
        "pm.max_children" = 32;
        "pm.start_servers" = 4;
        "pm.min_spare_servers" = 2;
        "pm.max_spare_servers" = 8;
        "pm.max_requests" = 500;
        "catch_workers_output" = true;
      }
      // cfg.poolConfig;
    };

    services.nginx = mkIf (cfg.nginx != null) {
      enable = mkDefault true;
      virtualHosts."${cfg.hostname}" = mkMerge [
        cfg.nginx
        {
          # don't allow to override the root easily, as it will almost
          # certainly break Admidio.
          root = mkForce dataDir;
          extraConfig = ''
            client_max_body_size ${cfg.maxUploadSize};
          '';
          locations = {
            # Admidio protects adm_my_files with a deny-all .htaccess under
            # Apache; under nginx it must never be reachable.
            "^~ /adm_my_files/" = {
              priority = 100;
              extraConfig = "return 403;";
            };
            # no dotfiles (.htaccess, .git, ...) are served
            "~ /\\." = {
              priority = 200;
              extraConfig = "return 403;";
            };
            "~ \\.php$" = {
              priority = 300;
              extraConfig = ''
                fastcgi_pass unix:${fpm.socket};
                fastcgi_index index.php;
                include ${config.services.nginx.package}/conf/fastcgi.conf;
                ${optionalString tlsEnabled "fastcgi_param HTTPS on;"}
              '';
            };
            # let browsers cache the static assets of the shipped themes
            "~* \\.(css|js|gif|jpe?g|png|ico|svg|woff2?)$" = {
              priority = 400;
              extraConfig = ''
                try_files $uri =404;
                expires 7d;
              '';
            };
            "/" = {
              priority = 900;
              index = "index.php";
              tryFiles = "$uri $uri/ =404";
            };
          };
        }
      ];
    };

    # The recurring work of an Admidio installation (the official Docker
    # image starts a cron service for this).
    systemd.services.admidio-maintenance = mkIf cfg.maintenance.enable {
      description = "Run the Admidio maintenance jobs";
      requires = [ "admidio-provision.service" ];
      after = [ "admidio-provision.service" ] ++ optional (databaseService != null) databaseService;
      wants = optional (databaseService != null) databaseService;
      serviceConfig = {
        Type = "oneshot";
        User = user;
        Group = group;
        WorkingDirectory = dataDir;
        ExecStart = "${php}/bin/php ${cliSocketFlag} ${cliScript} maintenance:run --yes";
      };
    };

    systemd.timers.admidio-maintenance = mkIf cfg.maintenance.enable {
      description = "Run the Admidio maintenance jobs periodically";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.maintenance.startAt;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    environment.systemPackages = [ admidioCli ];
  };
}
