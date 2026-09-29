#!/bin/bash
#
# install.sh - installer bundled inside the fractalsql-mysql macOS zip.
# Run it from the extracted zip directory, against an already running
# MySQL server (this only installs the plugin, not MySQL itself):
#
#     unzip fractalsql-mysql-osx_arm64.zip -d fractalsql-mysql-darwin
#     cd fractalsql-mysql-darwin
#     ./install.sh                                  # mysql -uroot on PATH
#     MYSQL_BIN=/path/to/mysql ./install.sh         # or a specific client
#
# Copies the UDF library and reasoning plugin into the server's
# plugin_dir, then registers the UDFs and procedures by running the two
# bundled SQL scripts against that same server.
#
# plugin_dir is read live with `SELECT @@plugin_dir` against the running
# server rather than from `mysql_config --plugindir`, which reports the
# client connector library's own plugin path, not the server's. Using
# it would copy the plugin somewhere the server never looks.
#
# One binary works across the supported MySQL majors (8.4 LTS, 9.7
# LTS, and 26.7), since the UDF ABI is stable across
# those majors (see
# docs/getting-started.md). There's no per-major build-vs-target check
# here because there's nothing to check.
#
# macOS has no package manager for MySQL UDF plugins the way
# Debian/RHEL have .deb/.rpm, so this zip plus installer script is the
# delivery vehicle here, matching the self-contained artifacts shipped
# for Linux and Windows.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MYSQL_BIN="${MYSQL_BIN:-mysql}"
if ! command -v "${MYSQL_BIN}" >/dev/null 2>&1; then
    echo "error: no mysql client found." >&2
    echo "  Put one on PATH, or run: MYSQL_BIN=/path/to/mysql ./install.sh" >&2
    echo "  Homebrew example: MYSQL_BIN=\$(brew --prefix mysql)/bin/mysql ./install.sh" >&2
    exit 1
fi
# Connection account. Fresh Homebrew MySQL (8.4 / 9.7 / 26.7) initializes
# root@localhost with an EMPTY password (mysqld --initialize-insecure
# semantics via the formula's default --initialize-insecure bootstrap),
# so a bare connect works. Fall back to an explicit -u root for
# passworded installs (running this script with MYSQL_PWD set, or older
# installs where a password was set manually).
MYSQL_AUTH=""
if "${MYSQL_BIN}" -Nse 'SELECT 1;' >/dev/null 2>&1; then
    :
elif "${MYSQL_BIN}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
    MYSQL_AUTH="-u root"
else
    echo "error: can't connect to a running MySQL server via ${MYSQL_BIN}." >&2
    echo "  This installs the plugin into an already-running server -- it doesn't start one." >&2
    echo "  Tried a bare connection and -u root. If root has a password," >&2
    echo "  export MYSQL_PWD (and MYSQL_HOST/MYSQL_TCP_PORT if the server" >&2
    echo "  isn't on the default socket) and re-run." >&2
    exit 1
fi

PLUGIN_DIR="$("${MYSQL_BIN}" ${MYSQL_AUTH} -Nse 'SELECT @@plugin_dir;' 2>/dev/null || true)"
PLUGIN_DIR="${PLUGIN_DIR%/}"
# Canonical (realpath-equal) form, not just slash-trimmed: the reasoning
# core rejects symlinked plugin paths ("reasoning plugin path is not
# canonical"), and @@plugin_dir under Homebrew is a symlink to the
# versioned Cellar dir -- the load instructions below must hand users a
# path that actually loads.
if [[ -n "${PLUGIN_DIR}" ]]; then
    PLUGIN_DIR="$(cd "${PLUGIN_DIR}" && pwd -P)" || {
        echo "error: can't resolve plugin dir to a physical path" >&2
        exit 1
    }
fi
if [[ -z "${PLUGIN_DIR}" ]]; then
    echo "error: SELECT @@plugin_dir returned nothing." >&2
    exit 1
fi

# macOS's dynamic loader is happy to load a .dylib under a name ending
# in .so, so it's staged here as fractalsql.so: every install_udf.sql
# CREATE FUNCTION ... SONAME 'fractalsql.so' reference expects that
# exact on-disk name, on every platform.
if [[ ! -f "${HERE}/fractalsql.dylib" ]]; then
    echo "error: fractalsql.dylib not found in ${HERE}" >&2
    exit 1
fi
if [[ ! -f "${HERE}/fractalsql-reasoning-http.so" ]]; then
    echo "error: fractalsql-reasoning-http.so not found in ${HERE}" >&2
    exit 1
fi

echo "plugin_dir : ${PLUGIN_DIR}"
echo

INSTALL="install"
if [[ ! -w "${PLUGIN_DIR}" ]]; then
    echo "note: ${PLUGIN_DIR} is not writable -- re-running the copy under sudo"
    echo "      (you may be prompted for your password)."
    INSTALL="sudo install"
fi

${INSTALL} -d "${PLUGIN_DIR}"
${INSTALL} -m 0755 "${HERE}/fractalsql.dylib" "${PLUGIN_DIR}/fractalsql.so"
${INSTALL} -m 0755 "${HERE}/fractalsql-reasoning-http.so" "${PLUGIN_DIR}/fractalsql-reasoning-http.so"

echo "Installed:"
echo "  ${PLUGIN_DIR}/fractalsql.so (from fractalsql.dylib)"
echo "  ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
echo

echo "Next: register the UDFs + procedures with the same account this"
echo "script connected as (mydb below must already exist -- the FUNCTION"
echo "definitions are server-global, but install_udf.sql also creates the"
echo "fractal_schema_context stored procedure, and CREATE PROCEDURE needs"
echo "a database selected):"
echo "  ${MYSQL_BIN} ${MYSQL_AUTH} mydb < ${HERE}/install_udf.sql"
echo "  ${MYSQL_BIN} ${MYSQL_AUTH} mydb < ${HERE}/install_agents.sql"
echo "  ${MYSQL_BIN} ${MYSQL_AUTH} -e 'SELECT fractal_edition(), fractal_version();'"
echo
echo "Reasoning is opt-in and set via a process environment variable, not"
echo "a SQL statement -- mysqld has no GUC/sysvar surface for this (see"
echo "docs/reasoning-setup.md). Set FRACTALSQL_REASONING_PLUGIN to:"
echo "  ${PLUGIN_DIR}/fractalsql-reasoning-http.so"
echo "in mysqld's environment (e.g. via 'brew services' launchd plist"
echo "overrides) before configuring an endpoint, then restart mysqld."