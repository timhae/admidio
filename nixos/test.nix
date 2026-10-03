/*
  Admidio NixOS test

  The same scenario is run against a locally created PostgreSQL database and a
  locally created MariaDB database, because the module supports both.

  It covers the following scenarios:
  - Building the application and provisioning it into /var/lib/admidio
  - Generation of adm_my_files/config.php from the module options
  - The nginx virtual host (static assets, protected adm_my_files)
  - A complete installation through the command line interface
  - Login through the web interface (php-fpm, database, session handling)
  - The recurring maintenance job
  - Re-provisioning after a version change keeps user data

  Scenarios NOT covered by this test:
  - Upgrades to a new Admidio release (covered partially by the version
    change re-provisioning subtest)
  - MySQL (as opposed to MariaDB), remote databases and SMTP mail delivery
  - LDAP, SAML and OAuth single sign-on
*/
_:
let
  adminPassword = "NixosAdmidioTest1234.";

  nodeConfig = dbType: {
    imports = [ ./module.nix ];

    services.admidio = {
      enable = true;
      hostname = "localhost";
      database = {
        createLocally = true;
        type = dbType;
      };
      nginx = {
        forceSSL = false;
        enableACME = false;
      };
    };
  };
in
{
  name = "admidio";

  nodes = {
    pgsql = nodeConfig "pgsql";
    mariadb = nodeConfig "mariadb";
  };

  testScript =
    { nodes, ... }:
    let
      dataDir = toString nodes.pgsql.services.admidio.dataDir;
      version = nodes.pgsql.services.admidio.package.version;
      packagePath = toString nodes.pgsql.services.admidio.package;
    in
    ''
      import json
      import re

      start_all()

      version = "${version}"
      dataDir = "${dataDir}"
      packagePath = "${packagePath}"

      def assert_table(machine, dbtype, table):
          if dbtype == "pgsql":
              machine.succeed(
                  "sudo -u postgres psql -d admidio -tAc"
                  " \"SELECT tablename FROM pg_tables WHERE schemaname = 'public'\""
                  f" | grep -x {table}"
              )
          else:
              machine.succeed(
                  f"mysql -N -e \"SHOW TABLES FROM admidio\" | grep -x {table}"
              )

      def run_scenario(machine, dbtype):
          if dbtype == "pgsql":
              # postgresql-setup.service creates the database and its user and
              # requires the PostgreSQL server itself
              machine.wait_for_unit("postgresql-setup.service")
          else:
              # mysql.service creates the local database and its user
              machine.wait_for_unit("mysql.service")
          machine.wait_for_unit("admidio-provision.service")
          machine.wait_for_unit("phpfpm-admidio.service")
          machine.wait_for_unit("nginx.service")

          with subtest(f"[{dbtype}] the application was provisioned into the data directory"):
              machine.succeed(f"test -f {dataDir}/index.php")
              machine.succeed(f"test -f {dataDir}/system/bootstrap/constants.php")
              machine.succeed(f"test -f {dataDir}/vendor/autoload.php")
              machine.succeed(
                  f"test \"$(cat {dataDir}/adm_my_files/.admidio_installed_version)\" = {version}"
              )

          with subtest(f"[{dbtype}] config.php was generated from the module options and stays private"):
              machine.succeed(f"test -f {dataDir}/adm_my_files/config.php")
              machine.succeed(
                  f"""test "$(stat -c %a {dataDir}/adm_my_files/config.php)" = 600"""
              )
              machine.succeed(
                  f"grep -q \"\\$gDbType = '{'pgsql' if dbtype == 'pgsql' else 'mysql'}';\" {dataDir}/adm_my_files/config.php"
              )
              machine.succeed(
                  f"grep -q \"\\$g_adm_db   = 'admidio';\" {dataDir}/adm_my_files/config.php"
              )
              if dbtype == "pgsql":
                  # the local PostgreSQL database is reached through its socket
                  machine.succeed(
                      f"grep -q \"\\$g_adm_srv  = '/run/postgresql';\" {dataDir}/adm_my_files/config.php"
                  )
              else:
                  # the local MariaDB database is reached through the unix socket
                  machine.succeed(
                      f"grep -q \"\\$g_adm_srv  = 'localhost';\" {dataDir}/adm_my_files/config.php"
                  )
              machine.succeed(
                  f"grep -q \"\\$g_adm_pw   = ''';\" {dataDir}/adm_my_files/config.php"
              )

          with subtest(f"[{dbtype}] the data directory is not readable by others"):
              machine.succeed(
                  f"""test "$(stat -c %a {dataDir}/adm_my_files)" = 700"""
              )
              # nginx must not be able to read the private data of Admidio
              machine.fail(
                  f"sudo -u nginx test -r {dataDir}/adm_my_files/config.php"
              )

          with subtest(f"[{dbtype}] static assets of the shipped theme are served by nginx"):
              machine.succeed("curl -sSf http://localhost/themes/simple/css/admidio.css > /dev/null")

          with subtest(f"[{dbtype}] adm_my_files is not reachable through nginx"):
              machine.fail("curl -sSf http://localhost/adm_my_files/index.html")

          with subtest(f"[{dbtype}] dotfiles are not reachable through nginx"):
              machine.fail("curl -sSf http://localhost/.admidio_image_version")

          with subtest(f"[{dbtype}] the installation wizard is reachable while Admidio is not installed"):
              machine.succeed("curl -sSfL http://localhost/ | grep '<title>Admidio'")

          with subtest(f"[{dbtype}] the command line installation finishes"):
              install_status, install_output = machine.execute(
                  "echo '${adminPassword}'"
                  " | admidio install:run --yes --language=en"
                  " --organization-shortname=TEST"
                  " --organization-name='Test Organization'"
                  " --organization-email=info@example.org"
                  " --admin-login=admin"
                  " --admin-first-name=Anna"
                  " --admin-last-name=Admin"
                  " --admin-email=anna@example.org"
                  " --admin-password-stdin"
              )
              print(install_output)
              assert install_status == 0, "admidio install:run failed"
              assert_table(machine, dbtype, "adm_sessions")
              assert_table(machine, dbtype, "adm_users")

          with subtest(f"[{dbtype}] the web interface is reachable after the installation"):
              machine.succeed("curl -sSfL http://localhost/ > /dev/null")
              machine.succeed("curl -sSfL http://localhost/ | grep 'Test Organization'")

          with subtest(f"[{dbtype}] the login page renders and shows the organization"):
              _, login_html = machine.execute(
                  "curl -sS -c /tmp/cookies http://localhost/system/login.php"
              )
              assert "Test Organization" in login_html, "organization missing on the login page"

              csrf_match = re.search(
                  r'name="adm_csrf_token"[^>]*value="([^"]*)"', login_html
              )
              assert csrf_match, "csrf token not found on the login page"
              csrf_token = csrf_match.group(1)

          with subtest(f"[{dbtype}] the administrator can log in"):
              _, login_result = machine.execute(
                  "curl -sS -b /tmp/cookies -c /tmp/cookies"
                  + " --data-urlencode adm_csrf_token=" + csrf_token
                  + " --data-urlencode usr_login_name=admin"
                  + " --data-urlencode usr_password=${adminPassword}"
                  + " 'http://localhost/system/login.php?mode=check'"
              )
              login_payload = json.loads(login_result)
              assert login_payload["status"] == "success", "login failed"

              _, overview_html = machine.execute(
                  "curl -sS -b /tmp/cookies -L http://localhost/modules/overview.php"
              )
              assert "Test Organization" in overview_html, "organization missing on the overview page"
              assert "Anna" in overview_html, "administrator missing on the overview page"

          with subtest(f"[{dbtype}] the recurring maintenance job runs"):
              machine.succeed("systemctl start admidio-maintenance.service")

          with subtest(f"[{dbtype}] re-provisioning after a version change keeps the installation"):
              # pretend an older version was installed to force the full rsync
              machine.succeed(
                  "echo '0.0.0' | "
                  f"sudo -u admidio tee {dataDir}/adm_my_files/.admidio_installed_version > /dev/null"
              )
              machine.succeed("systemctl restart admidio-provision.service")
              # the php-fpm pool is restarted with the re-provisioned application
              machine.wait_for_unit("phpfpm-admidio.service")
              machine.succeed(
                  f"test \"$(cat {dataDir}/adm_my_files/.admidio_installed_version)\" = {version}"
              )
              # user data and the installation survive the re-provisioning
              assert_table(machine, dbtype, "adm_users")
              machine.succeed(
                  f"test \"$(stat -c %a {dataDir}/adm_my_files/config.php)\" = 600"
              )
              machine.succeed(
                  "curl -sSfL http://localhost/ | grep 'Test Organization'"
              )

          with subtest(f"[{dbtype}] re-provisioning after a package change keeps the installation"):
              # A rebuild changes the package store path but keeps the version. The
              # provision service must still copy the new code, otherwise a running
              # installation never sees fixes that do not bump the version. Simulate
              # the rebuild by staling the package marker and dropping a sentinel
              # into a directory that the code rsync replaces with --delete.
              sentinel = f"{dataDir}/src/.package-reprovision-sentinel"
              customTemplate = f"{dataDir}/adm_my_files/mail_templates/custom-reprovision.html"
              machine.succeed(f"sudo -u admidio touch {sentinel}")
              machine.succeed(
                  f"echo '#custom#' | sudo -u admidio tee {customTemplate} > /dev/null"
              )
              machine.succeed(
                  "echo 'stale-package' | "
                  f"sudo -u admidio tee {dataDir}/adm_my_files/.admidio_installed_package > /dev/null"
              )
              machine.succeed("systemctl restart admidio-provision.service")
              machine.wait_for_unit("phpfpm-admidio.service")
              # the code rsync ran even though the version did not change
              machine.fail(f"test -e {sentinel}")
              machine.succeed(
                  f"test \"$(cat {dataDir}/adm_my_files/.admidio_installed_package)\" = {packagePath}"
              )
              machine.succeed(
                  f"test \"$(cat {dataDir}/adm_my_files/.admidio_installed_version)\" = {version}"
              )
              # an administrator's mail template is not overwritten by the defaults
              machine.succeed(f"grep -q '#custom#' {customTemplate}")
              # the application is still served
              machine.succeed(
                  "curl -sSfL http://localhost/ | grep 'Test Organization'"
              )

          with subtest(f"[{dbtype}] the maintenance timer is enabled"):
              machine.succeed("systemctl is-enabled admidio-maintenance.timer")

      run_scenario(pgsql, "pgsql")
      run_scenario(mariadb, "mariadb")
    '';
}
