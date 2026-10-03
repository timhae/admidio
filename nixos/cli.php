<?php
/**
 ***********************************************************************************************
 * Command line helper of the NixOS services.admidio module.
 *
 * Admidio 5.0 has no command line administration utility. This script provides the two
 * commands the module needs for a non-interactive installation and for the recurring
 * maintenance jobs. It reuses the same installation step and maintenance classes as the
 * web interface, so the result is identical to an installation through the wizard.
 *
 * Usage:
 *   php cli.php install:run --language=en --organization-shortname=NAME ...
 *     --organization-name=NAME --organization-email=EMAIL --admin-login=LOGIN
 *     --admin-first-name=NAME --admin-last-name=NAME --admin-email=EMAIL
 *     --admin-password-stdin
 *   php cli.php maintenance:run [--yes]
 *
 * @copyright The Admidio Team
 * @see https://www.admidio.org/
 * @license https://www.gnu.org/licenses/gpl-2.0.html GNU General Public License v2.0 only
 ***********************************************************************************************
 */

use Admidio\Infrastructure\Database;
use Admidio\Infrastructure\Entity\Entity;
use Admidio\Infrastructure\Language;
use Admidio\Infrastructure\Utils\Maintenance;
use Admidio\InstallationUpdate\Service\Installation;
use Admidio\Organizations\Entity\Organization;

if (PHP_SAPI !== 'cli') {
    exit('This script may only be called from the command line.');
}

/**
 * Fill the request variables Admidio reads while bootstrapping. A CLI process has no HTTP
 * request, so the URL constants of system/bootstrap/constants.php need deterministic values.
 */
function admidioCliRequestVariables(string $rootPath, string $host, int $port, string $urlPath = ''): void
{
    $_SERVER['HTTP_HOST'] = $host;
    $_SERVER['SERVER_NAME'] = $host;
    $_SERVER['SERVER_PORT'] = $port;
    $_SERVER['SERVER_PROTOCOL'] = 'HTTP/1.1';
    $_SERVER['REQUEST_METHOD'] = 'GET';
    $_SERVER['REMOTE_ADDR'] = '127.0.0.1';
    $_SERVER['DOCUMENT_ROOT'] = $rootPath;
    $_SERVER['SCRIPT_FILENAME'] = $rootPath . '/index.php';
    $_SERVER['SCRIPT_NAME'] = $urlPath . '/index.php';
    $_SERVER['REQUEST_URI'] = $urlPath . '/index.php';
}

/**
 * Fill the request variables out of the configured root URL of the installation.
 */
function admidioCliRequestVariablesFromUrl(string $rootPath, string $rootUrl): void
{
    $url = parse_url($rootUrl);
    $scheme = is_array($url) && isset($url['scheme']) ? $url['scheme'] : 'http';
    $host = is_array($url) && isset($url['host']) ? $url['host'] : 'localhost';
    $port = is_array($url) && isset($url['port'])
        ? (int)$url['port']
        : ($scheme === 'https' ? 443 : 80);
    $urlPath = is_array($url) && isset($url['path']) ? rtrim($url['path'], '/') : '';

    admidioCliRequestVariables($rootPath, $host, $port, $urlPath);
}

/**
 * Parse --name=value and --flag arguments; all options of this script use that form.
 *
 * @param array<int,string> $arguments
 * @return array<string,string|bool>
 */
function admidioCliOptions(array $arguments): array
{
    $options = array();

    foreach ($arguments as $argument) {
        if (!str_starts_with($argument, '--')) {
            continue;
        }

        $name = substr($argument, 2);
        $value = true;

        $separator = strpos($name, '=');
        if ($separator !== false) {
            $value = substr($name, $separator + 1);
            $name = substr($name, 0, $separator);
        }

        $options[$name] = $value;
    }

    return $options;
}

/**
 * @param array<string,string|bool> $options
 */
function admidioCliRequiredOption(array $options, string $name): string
{
    $value = isset($options[$name]) ? (string)$options[$name] : '';
    if ($value === '') {
        fwrite(STDERR, 'admidio: missing required option --' . $name . "\n");
        exit(1);
    }

    return $value;
}

$rootPath = getcwd();
$configPath = $rootPath . '/adm_my_files/config.php';
if (!is_file($configPath)) {
    fwrite(STDERR, 'admidio: configuration file ' . $configPath . " was not found\n");
    exit(1);
}

$command = isset($argv[1]) ? $argv[1] : '';
$options = admidioCliOptions(array_slice($argv, 2));

// config.php may select database settings by the request host
admidioCliRequestVariables($rootPath, 'localhost', 80);
require_once $configPath;

// An HTTP redirect has no meaning in a CLI process.
$gForceHTTPS = false;

admidioCliRequestVariablesFromUrl($rootPath, $g_root_path);
require_once $rootPath . '/system/bootstrap/bootstrap.php';

switch ($command) {
    case 'install:run':
        if (isset($options['admin-password'])) {
            $adminPassword = (string)$options['admin-password'];
        } elseif (isset($options['admin-password-stdin'])) {
            $adminPassword = rtrim((string)stream_get_contents(STDIN), "\r\n");
        } else {
            fwrite(STDERR, "admidio: install:run needs --admin-password-stdin\n");
            exit(1);
        }
        if ($adminPassword === '') {
            fwrite(STDERR, "admidio: the administrator password is empty\n");
            exit(1);
        }

        $language = isset($options['language']) && $options['language'] !== ''
            ? (string)$options['language']
            : 'en';
        $gL10n = new Language($language);
        $gDb = Database::createDatabaseInstance();
        $db = $gDb;

        Entity::setLoggingEnabled(false);
        Installation::checkFolderPermissions();

        // start_installation.php reads the data it would normally get from the wizard forms
        // out of the session. This is the same data the form validation of the wizard stores.
        $sessionPath = $rootPath . '/adm_my_files/temp';
        if (!is_dir($sessionPath)) {
            mkdir($sessionPath, 0750, true);
        }
        session_save_path($sessionPath);
        session_name('ADMIDIO_INSTALLATION');
        session_start();

        $_SESSION['db_engine'] = DB_ENGINE;
        $_SESSION['db_host'] = DB_HOST;
        $_SESSION['db_port'] = DB_PORT;
        $_SESSION['db_name'] = DB_NAME;
        $_SESSION['db_username'] = DB_USERNAME;
        $_SESSION['db_password'] = DB_PASSWORD;
        $_SESSION['table_prefix'] = TABLE_PREFIX;

        $_SESSION['orga_shortname'] = admidioCliRequiredOption($options, 'organization-shortname');
        $_SESSION['orga_longname'] = admidioCliRequiredOption($options, 'organization-name');
        $_SESSION['orga_email'] = admidioCliRequiredOption($options, 'organization-email');
        $_SESSION['orga_timezone'] = $gTimezone;

        $_SESSION['user_login'] = admidioCliRequiredOption($options, 'admin-login');
        $_SESSION['user_first_name'] = admidioCliRequiredOption($options, 'admin-first-name');
        $_SESSION['user_last_name'] = admidioCliRequiredOption($options, 'admin-last-name');
        $_SESSION['user_email'] = admidioCliRequiredOption($options, 'admin-email');
        $_SESSION['user_password'] = $adminPassword;
        $_SESSION['user_password_confirm'] = $adminPassword;

        require ADMIDIO_PATH . '/install/install_steps/start_installation.php';
        break;

    case 'maintenance:run':
        $gDb = Database::createDatabaseInstance();
        $gCurrentUserId = 0;
        $gCurrentOrganization = Organization::createDefaultOrganizationObject(
            $gDb,
            isset($g_organization) ? $g_organization : ''
        );
        $gCurrentOrgId = (int)$gCurrentOrganization->getValue('org_id');
        $gSettingsManager =& $gCurrentOrganization->getSettingsManager();
        $gL10n = new Language($gSettingsManager->getString('system_language'));

        Entity::setLoggingEnabled(false);

        // Admidio 5.0 provides the category reorganization and the repair of the
        // documents/files paths as maintenance jobs.
        $maintenance = new Maintenance($gDb);
        $maintenance->reorganizeCategories();
        $maintenance->repairDocumentsFilesPath();
        break;

    default:
        fwrite(
            STDERR,
            "Usage: admidio install:run [options]\n"
            . "       admidio maintenance:run\n"
        );
        exit(1);
}
