#!/bin/bash
#
# scripts/easy_install.sh
#
# The "easy button" for FractalSQL. One command gets you from a bare
# Linux or macOS box to a running install with reasoning configured.
#
# Usage (fresh machine, nothing installed yet):
#   curl -fsSL https://github.com/FractalSQLabs/fractalsql-mysql/releases/latest/download/easy_install.sh | bash
#
# Usage (package already installed via apt/dnf/tarball yourself):
#   ./easy_install.sh              # detects it, skips straight to the wizard
#
# Flags (all optional. Anything you omit gets asked interactively):
#   --database <name>          target database for the agent stored
#                               procedures (UDFs are server-global, no
#                               database needed, but CREATE PROCEDURE
#                               requires one -- must already exist)
#   --provider ollama|openai-compatible|skip
#   --url <chat-completions-url>       --model <name>
#   --embed-url <url>                  --embed-model <name>
#   --token <token>            (prefer leaving this to the masked prompt)
#   --think <off|low|medium|high|...>  --think-provider <ollama|openai|...>
#   --yes                      pre-confirm every prompt (needed for CI/non-tty)
#   --no-install               don't offer to install a missing package
#   --dry-run                  print what would happen, change nothing
#   --force-reinstall          skip the "already registered" pause
#   --uninstall                reverse everything this script can set up
#   --version <X.Y.Z>          package version to install (default: this script's own)
#   -h, --help
#
# Env vars:
#   MYSQL_BINDIR               bin dir of an existing MySQL install: when set
#                               and non-empty, use it directly
#                               (e.g. MYSQL_BINDIR=/opt/homebrew/opt/mysql/bin)
#                               and skip auto-detection entirely.
#
# No telemetry. This script never reports usage, provider choice, or
# success/failure anywhere. That's deliberate, matching FractalSQL's own
# "sovereign reasoning" positioning: your infra choices stay yours.
#
# Design differences, all forced by MySQL's own architecture (see
# docs/reasoning-setup.md):
#   - No per-major-version selector. One binary covers MySQL
#     8.4 LTS, 9.7 LTS, and 26.7 (the UDF ABI is
#     stable across them, see scripts/package.sh), and there's no
#     Debian-style multi-cluster
#     concept -- normally exactly one mysqld instance to target.
#   - No sysvar/`SET GLOBAL`-style config surface exists for these. Every
#     FRACTALSQL_* reasoning setting is a process environment variable
#     read once by mysqld at startup, so applying any of them needs a
#     restart, not just a reload.
#   - Registration is two plain SQL
#     files (sql/install_udf.sql + sql/install_agents.sql), not
#     `CREATE EXTENSION` -- there's no catalog-version/staleness concept
#     to detect, since both scripts are unconditionally idempotent
#     (DROP ... IF EXISTS then CREATE). UDFs are also server-global, not
#     per-database.
#   - Verification functions are fractal_edition()/fractal_version()
#     (the fractalsql_ prefix; agent functions use fractal_ instead, see
#     sql/install_udf.sql).
#
# Runs fine piped from curl. Every prompt reads from /dev/tty directly,
# not stdin, since stdin is the pipe's source in `curl ... | bash`.

set -euo pipefail

# --- version -----------------------------------------------------------
# Stamped in by release.yml at build time (the placeholder below is
# replaced with the tag version before this file is uploaded as a release
# asset). Falls back to reading src/fractalsql.c directly when run from a
# repo checkout during development, so this script works untouched both
# as a release asset and as a dev/test tool.
FSQL_VERSION="@@FSQL_VERSION@@"
if [[ "${FSQL_VERSION}" == "@@FSQL_VERSION@@" ]]; then
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${HERE}/../src/fractalsql.c" ]]; then
        FSQL_VERSION="$(sed -n 's/^#define FSQL_VERSION "\(.*\)"$/\1/p' "${HERE}/../src/fractalsql.c")"
    fi
fi

REPO="FractalSQLabs/fractalsql-mysql"

# --- output helpers ------------------------------------------------------
if [[ -t 1 ]]; then G="\033[32m"; R="\033[31m"; Y="\033[33m"; B="\033[1m"; Z="\033[0m"; else G=""; R=""; Y=""; B=""; Z=""; fi
log()  { printf "${B}==>${Z} %s\n" "$1"; }
ok()   { printf "  ${G}✓${Z} %s\n" "$1"; }
warn() { printf "  ${Y}!${Z} %s\n" "$1" >&2; }
err()  { printf "  ${R}✗${Z} %s\n" "$1" >&2; }
die()  { err "$1"; exit 1; }

# --- /dev/tty-aware prompting --------------------------------------------
YES=0
NO_INSTALL=0
DRY_RUN=0
FORCE_REINSTALL=0
UNINSTALL=0
INSTALL_VERSION="${FSQL_VERSION}"
DATABASE=""
PROVIDER=""
HTTP_URL=""
HTTP_MODEL=""
HTTP_TOKEN=""
HTTP_EMBED_URL=""
HTTP_EMBED_MODEL=""
HTTP_THINK=""
HTTP_THINK_PROVIDER=""

have_tty() { [[ -e /dev/tty ]]; }

confirm() {  # confirm "question" -> 0=yes 1=no
    local question="$1"
    [[ "${YES}" -eq 1 ]] && { ok "${question} -> yes (--yes)"; return 0; }
    if ! have_tty; then
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass --yes, or the specific flag for what you're trying to set."
    fi
    local reply
    read -r -p "${question} [Y/n] " reply < /dev/tty || true
    [[ -z "${reply}" || "${reply}" =~ ^[Yy] ]]
}

prompt() {  # prompt "question" "default" -> echoes the answer
    local question="$1" default="${2:-}" reply
    if ! have_tty; then
        [[ -n "${default}" ]] && { echo "${default}"; return; }
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass the corresponding flag."
    fi
    if [[ -n "${default}" ]]; then
        read -r -p "${question} [${default}]: " reply < /dev/tty || true
        echo "${reply:-${default}}"
    else
        read -r -p "${question}: " reply < /dev/tty || true
        echo "${reply}"
    fi
}

prompt_secret() {  # prompt_secret "question" -> echoes the answer, never displayed
    local question="$1" reply
    if ! have_tty; then
        die "'${question}' needs an answer but there's no terminal to ask (running non-interactively). Pass --token."
    fi
    read -r -s -p "${question}: " reply < /dev/tty || true
    echo >&2
    echo "${reply}"
}

# --- arg parsing -----------------------------------------------------------
usage() { sed -n '2,62p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --database)          DATABASE="$2"; shift 2 ;;
        --provider)          PROVIDER="$2"; shift 2 ;;
        --url)                HTTP_URL="$2"; shift 2 ;;
        --model)            HTTP_MODEL="$2"; shift 2 ;;
        --token)            HTTP_TOKEN="$2"; shift 2 ;;
        --embed-url)     HTTP_EMBED_URL="$2"; shift 2 ;;
        --embed-model) HTTP_EMBED_MODEL="$2"; shift 2 ;;
        --think)              HTTP_THINK="$2"; shift 2 ;;
        --think-provider) HTTP_THINK_PROVIDER="$2"; shift 2 ;;
        --version)      INSTALL_VERSION="$2"; shift 2 ;;
        --yes)               YES=1; shift ;;
        --no-install)  NO_INSTALL=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --force-reinstall) FORCE_REINSTALL=1; shift ;;
        --uninstall)     UNINSTALL=1; shift ;;
        -h|--help)       usage ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

[[ -n "${INSTALL_VERSION}" ]] || die "could not determine a version to install. Pass --version X.Y.Z"

# --- OS detection -----------------------------------------------------
OS_FAMILY=""   # debian | rhel | darwin
PKG_MGR=""     # dnf | yum | zypper (only set when OS_FAMILY=rhel)
ARCH_UNAME="$(uname -m)"
case "${ARCH_UNAME}" in
    x86_64|amd64) ARCH_DEB="amd64"; ARCH_DARWIN="x86_64" ;;
    arm64|aarch64) ARCH_DEB="arm64"; ARCH_DARWIN="arm64" ;;
    *) die "unsupported architecture: ${ARCH_UNAME}" ;;
esac

detect_os() {
    case "$(uname -s)" in
        Darwin) OS_FAMILY="darwin" ;;
        Linux)
            # OS_FAMILY collapse: dnf/yum/
            # zypper all resolve to "rhel" here, since Oracle's MySQL
            # community repo setup (mysql84-community-release) targets
            # all of them similarly -- the one real difference is the
            # install command itself (PKG_MGR below): zypper enforces
            # signature checks on locally-supplied RPMs by default and
            # needs --no-gpg-checks; dnf/yum don't.
            if command -v apt-get >/dev/null 2>&1; then OS_FAMILY="debian"
            elif command -v dnf >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="dnf"
            elif command -v yum >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="yum"
            elif command -v zypper >/dev/null 2>&1; then OS_FAMILY="rhel"; PKG_MGR="zypper"
            else
                die "unsupported Linux distro (need apt-get, dnf, yum, or zypper; Alpine isn't packaged yet)"
            fi
            ;;
        *) die "unsupported OS: $(uname -s). This script covers Linux and macOS. See easy_install.ps1 for Windows." ;;
    esac
}

# --- mysql_config / plugin_dir plumbing -----------------------------------
MYSQL_CONFIG_BIN=""
PLUGIN_DIR=""

detect_mysql() {
    # Same override convention as the Makefile's own mysql_config lookup:
    # when MYSQL_BINDIR is set and non-empty, trust it completely and
    # skip auto-detection.
    local candidates=() c
    if [[ -n "${MYSQL_BINDIR:-}" ]]; then
        candidates+=("${MYSQL_BINDIR}/mysql_config")
    else
        command -v mysql_config >/dev/null 2>&1 && candidates+=("$(command -v mysql_config)")
        for c in /opt/homebrew/opt/mysql/bin/mysql_config \
                 /opt/homebrew/opt/mysql@8.4/bin/mysql_config \
                 /usr/local/opt/mysql/bin/mysql_config \
                 /usr/local/opt/mysql@8.4/bin/mysql_config; do
            [[ -x "$c" ]] && candidates+=("$c")
        done
        if command -v brew >/dev/null 2>&1; then
            for c in "$(brew --prefix)/bin/mysql_config" \
                     "$(brew --prefix)/opt/mysql@8.4/bin/mysql_config"; do
                [[ -x "$c" ]] && candidates+=("$c")
            done
        fi
    fi
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] || continue
        MYSQL_CONFIG_BIN="$c"
        break
    done
    if [[ -z "${MYSQL_CONFIG_BIN}" ]]; then
        # Debian/Ubuntu's mysql-server package ships no mysql_config (that
        # comes with libmysqlclient-dev), but MYSQL_CONFIG_BIN is only
        # used below as an anchor to locate the client sitting next to it
        # -- so fall back to whatever mysql client is on PATH.
        if command -v mysql >/dev/null 2>&1; then
            MYSQL_CONFIG_BIN="$(dirname "$(command -v mysql)")/mysql_config"
        fi
    fi
    [[ -n "${MYSQL_CONFIG_BIN}" ]] || die "no mysql_config or mysql client found (checked PATH, MYSQL_BINDIR and common Homebrew paths, including the keg-only mysql@8.4). Set MYSQL_BINDIR to the bin/ directory of your MySQL install."
    # mysql_config --plugindir only anchors the mysql client binary below
    # (via resolve_mysql_as). `--plugindir` itself reports the client
    # connector library's own plugin path (for client-side auth plugins),
    # which is a different directory from the server's plugin_dir on
    # Debian/Ubuntu -- CREATE FUNCTION only looks in the server's.
    # PLUGIN_DIR is set from a live `SELECT @@plugin_dir` query once
    # resolve_mysql_as connects, with the mysql_config value as fallback,
    # see main().
}

is_installed() {
    [[ -f "${PLUGIN_DIR}/fractalsql.so" ]] || [[ -f "${PLUGIN_DIR}/fractalsql.dylib" ]]
}

# --- mysql client plumbing ------------------------------------------------
# Uses the mysql client next to MYSQL_CONFIG_BIN, not whatever happens to
# be on PATH.
#
# Connection: try the invoking user directly first (auth_socket auth,
# the default for root@localhost on a fresh Debian/Ubuntu mysql-server
# install -- the distro package auto-initializes the datadir that way;
# Homebrew initializes root@localhost with an EMPTY password). Fall back
# to `sudo mysql` (needed when the invoking user isn't the
# socket-authenticated account).
MYSQL_AS=()
resolve_mysql_as() {
    local bin; bin="$(dirname "${MYSQL_CONFIG_BIN}")/mysql"
    [[ -x "${bin}" ]] || die "mysql client not found next to ${MYSQL_CONFIG_BIN}"
    # Homebrew's MySQL creates root@localhost with an empty password
    # (mysqld --initialize-insecure semantics via the formula's bootstrap).
    # Debian/Ubuntu mysql-server makes root@localhost auth_socket. So try
    # the invoking user's own account first, then -u root (installs where
    # root still has an empty native password, or running as root), then
    # sudo.
    if "${bin}" -Nse 'SELECT 1;' >/dev/null 2>&1; then
        MYSQL_AS=("${bin}")
    elif "${bin}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
        MYSQL_AS=("${bin}" -u root)
    elif command -v sudo >/dev/null 2>&1 && sudo "${bin}" -u root -Nse 'SELECT 1;' >/dev/null 2>&1; then
        MYSQL_AS=(sudo "${bin}" -u root)
    else
        die "can't connect to mysqld as root, either directly or via 'sudo'. Check the server is running and that root@localhost uses auth_socket auth (the Debian/Ubuntu packaged default) or an empty password (the Homebrew default), or pass a working \$HOME/.my.cnf."
    fi
    # The one authoritative source for plugin_dir -- see detect_mysql's
    # own comment for why mysql_config --plugindir can't be trusted for
    # this on Debian/Ubuntu. Live query first, mysql_config --plugindir
    # (Makefile convention) as fallback, then the per-distro layout
    # guess: RPM/OL installs to /usr/lib64/mysql/plugin, Debian/Ubuntu
    # to /usr/lib/mysql/plugin, Homebrew to $(brew --prefix)/lib/plugin.
    PLUGIN_DIR="$("${MYSQL_AS[@]}" -Nse 'SELECT @@plugin_dir;' 2>/dev/null || true)"
    if [[ -z "${PLUGIN_DIR}" ]]; then
        if [[ -x "${MYSQL_CONFIG_BIN}" ]]; then
            PLUGIN_DIR="$("${MYSQL_CONFIG_BIN}" --plugindir 2>/dev/null || true)"
        fi
    fi
    if [[ -z "${PLUGIN_DIR}" ]]; then
        if command -v brew >/dev/null 2>&1; then
            PLUGIN_DIR="$(brew --prefix)/lib/plugin"
        elif [[ -d /usr/lib64/mysql/plugin ]]; then
            PLUGIN_DIR="/usr/lib64/mysql/plugin"
        else
            PLUGIN_DIR="/usr/lib/mysql/plugin"
        fi
        warn "PLUGIN_DIR guessed as ${PLUGIN_DIR} (no live server answer and no mysql_config)."
    fi
    PLUGIN_DIR="${PLUGIN_DIR%/}"
    # The reasoning core requires a canonical plugin path (the
    # configured value must equal its own realpath), and @@plugin_dir
    # runs through Homebrew's /opt/homebrew/opt/mysql symlink on
    # macOS -- writing that symlinked form to the env file would be
    # rejected at load time ("reasoning plugin path is not canonical").
    # Resolve to the physical directory once, here.
    RESOLVED_PLUGIN_DIR="$(cd "${PLUGIN_DIR}" && pwd -P)" \
        || die "can't resolve plugin dir '${PLUGIN_DIR}' to a physical path"
    PLUGIN_DIR="${RESOLVED_PLUGIN_DIR}"
}

# --- Phase B: install the package (default-on) ------------------------
phase_b_install() {
    if is_installed; then return; fi
    if [[ "${NO_INSTALL}" -eq 1 ]]; then
        die "FractalSQL isn't installed in ${PLUGIN_DIR}. Grab the matching package from https://github.com/${REPO}/releases and install it, then re-run this script (or drop --no-install)."
    fi
    confirm "FractalSQL isn't installed yet. Install it now?" \
        || die "Nothing to do without installing the package first. Re-run without --no-install, or install it yourself from https://github.com/${REPO}/releases."

    local asset_base="https://github.com/${REPO}/releases/download/v${INSTALL_VERSION}"
    # Global, not local: an EXIT trap runs after set -e has already
    # unwound out of this function on a failing command below, at which
    # point a `local` variable here would no longer exist and `set -u`
    # would reject the trap's own reference to it as unbound.
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "${TMP_DIR}"' EXIT

    case "${OS_FAMILY}" in
        debian)
            local asset="fractalsql-mysql-${ARCH_DEB}.deb"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            log "sudo apt-get install -y ${TMP_DIR}/${asset}"
            [[ "${DRY_RUN}" -eq 1 ]] || sudo apt-get install -y "${TMP_DIR}/${asset}"
            ;;
        rhel)
            local asset="fractalsql-mysql-${ARCH_DEB}.rpm"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            if [[ "${PKG_MGR}" == "zypper" ]]; then
                # zypper enforces signature checks by default, even for a
                # locally-supplied file; dnf/yum don't.
                log "sudo zypper --non-interactive --no-gpg-checks install ${TMP_DIR}/${asset}"
                [[ "${DRY_RUN}" -eq 1 ]] || sudo zypper --non-interactive --no-gpg-checks install "${TMP_DIR}/${asset}"
            else
                log "sudo ${PKG_MGR} install -y ${TMP_DIR}/${asset}"
                [[ "${DRY_RUN}" -eq 1 ]] || sudo "${PKG_MGR}" install -y "${TMP_DIR}/${asset}"
            fi
            ;;
        darwin)
            local platform_tag="osx_${ARCH_DARWIN}"
            [[ "${ARCH_DARWIN}" == "x86_64" ]] && platform_tag="osx_amd64"
            [[ "${ARCH_DARWIN}" == "arm64" ]] && platform_tag="osx_arm64"
            local asset="fractalsql-mysql-${platform_tag}.zip"
            log "Downloading ${asset}..."
            curl -fsSL "${asset_base}/${asset}" -o "${TMP_DIR}/${asset}"
            (cd "${TMP_DIR}" && unzip -q "${asset}" -d extracted)
            log "Running the bundled install.sh (reused, not reimplemented)..."
            local my_bin; my_bin="$(dirname "${MYSQL_CONFIG_BIN}")/mysql"
            [[ "${DRY_RUN}" -eq 1 ]] || MYSQL_BIN="${my_bin}" "${TMP_DIR}/extracted/install.sh"
            ;;
    esac
    ok "Package installed."
}

# --- Phase C: the wizard -----------------------------------------------
# Doubles any single quote in a value before it goes inside a shell-quoted
# EnvironmentFile / launchctl / registry write. Values here come from user
# input (a URL, a model name, a token). Done with an explicit loop rather
# than a ${1//\'/...} expansion: getting the backslash quoting of that
# replacement right is fragile in a way bash -n won't catch, and a wrong
# result writes an /etc/default/mysql line that no longer parses.
envq() {
    local rest="$1" out=""
    while [[ "${rest}" == *\'* ]]; do
        out+="${rest%%\'*}"        # text up to the quote
        out+="'\''"                # close the field, escaped quote, reopen
        rest="${rest#*\'}"         # skip past the quote
    done
    printf '%s' "${out}${rest}"
}

FSQL_ENV_ALL_KEYS=(FRACTALSQL_REASONING_PLUGIN FRACTALSQL_HTTP_URL FRACTALSQL_HTTP_TOKEN
    FRACTALSQL_HTTP_MODEL FRACTALSQL_HTTP_ALLOW_PLAINTEXT FRACTALSQL_HTTP_EMBED_URL
    FRACTALSQL_HTTP_EMBED_MODEL FRACTALSQL_HTTP_THINK FRACTALSQL_HTTP_THINK_PROVIDER
    FSQL_REASONING_HTTP_TIMEOUT_MS FSQL_REASONING_HTTP_LOW_SPEED_SECS)
# bash 3.2 -- macOS's stock shell -- has no associative arrays ("declare -A"
# fails outright there), so the wizard's config state is two parallel
# indexed arrays, kept in insertion order by env_set.
FSQL_ENV_KEYS=()
FSQL_ENV_VALUES=()
env_set() { env_set_raw "FRACTALSQL_$1" "$2"; }
env_set_raw() {
    local k="$1" i
    for i in "${!FSQL_ENV_KEYS[@]}"; do
        if [[ "${FSQL_ENV_KEYS[i]}" = "${k}" ]]; then
            FSQL_ENV_VALUES[i]="$2"
            return
        fi
    done
    FSQL_ENV_KEYS+=("${k}")
    FSQL_ENV_VALUES+=("$2")
}

# Applies FSQL_ENV_VALUES to mysqld's environment and restarts it, or
# prints the manual steps if the user declines / --dry-run. There is no
# reload path here at all (see this file's own header comment) --
# ALL of Phase C funnels through this.
have_systemd() { [[ -d /run/systemd/system ]]; }

# Debian/Ubuntu containers (Docker's own base images, this project's own
# docker/Dockerfile, and most CI test containers) run mysqld directly,
# with no systemd PID 1 at all -- `systemctl restart mysql` simply
# fails there, systemd unit or not. A real Debian/Ubuntu HOST install
# always has systemd, so that's still the first choice; this fallback
# mirrors install-test.yml's own debian-install job restart primitive
# (mysqld --user=mysql &, then poll mysqladmin ping) for the
# container case, rather than assuming systemd or giving up.
restart_mysqld_direct() {
    local priv_fn="$1"
    "${priv_fn}" mysqladmin -u root shutdown 2>/dev/null \
        || "${priv_fn}" pkill -TERM mysqld 2>/dev/null || true
    for _ in $(seq 1 30); do
        mysqladmin -u root ping >/dev/null 2>&1 || break
        sleep 1
    done
    # /etc/default/mysql is normally sourced by the packaged init/systemd
    # configuration -- NOT by mysqld itself. Since this fallback bypasses
    # both, source it explicitly before relaunching, or every
    # FRACTALSQL_* value apply_env_and_restart just wrote would silently
    # never reach the new process.
    "${priv_fn}" bash -c '[ -f /etc/default/mysql ] && set -a && . /etc/default/mysql && set +a; mysqld --user=mysql >/var/log/mysql/fractalsql-restart.log 2>&1 &' \
        || die "couldn't relaunch mysqld directly (no systemd found, and this fallback also failed). Restart it yourself, however it was started."
    local i
    for i in $(seq 1 60); do
        mysqladmin -u root ping >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "mysqld didn't come back up within 60s of the direct restart."
}

apply_env_and_restart() {
    local envfile dropin_dir dropin restart_cmd
    local as_root=0; [[ "$(id -u)" -eq 0 ]] && as_root=1
    priv() {
        local skip="$1"; shift
        if [[ "${skip}" -eq 1 ]]; then "$@"; else
            command -v sudo >/dev/null 2>&1 \
                || die "this needs root privileges but 'sudo' isn't installed and you're not root. Install sudo, or re-run as root."
            sudo "$@"
        fi
    }
    priv_as_root() { priv "${as_root}" "$@"; }

    log "About to set (mysqld environment):"
    local i k v
    for i in "${!FSQL_ENV_KEYS[@]}"; do
        k="${FSQL_ENV_KEYS[i]}"; v="${FSQL_ENV_VALUES[i]}"
        if [[ "$k" == *HTTP_TOKEN* ]]; then
            echo "  ${k}=***"
        else
            echo "  ${k}=${v}"
        fi
    done
    confirm "Apply this configuration? This needs a mysqld restart, which drops active connections -- there is no live reload for these." \
        || { warn "Aborted. Nothing was changed."; return 1; }

    case "${OS_FAMILY}" in
        debian)
            envfile="/etc/default/mysql"
            if have_systemd; then
                restart_cmd="systemctl restart mysql"
            else
                restart_cmd="mysqladmin -u root shutdown && mysqld --user=mysql &"
            fi
            [[ "${as_root}" -eq 1 ]] || restart_cmd="sudo ${restart_cmd}"
            if [[ "${DRY_RUN}" -eq 1 ]]; then log "(--dry-run: not actually writing or restarting)"; return 0; fi
            for k in "${FSQL_ENV_ALL_KEYS[@]}"; do
                priv "${as_root}" sed -i "/^${k}=/d" "${envfile}" 2>/dev/null || true
            done
            {
                for i in "${!FSQL_ENV_KEYS[@]}"; do
                    printf "%s='%s'\n" "${FSQL_ENV_KEYS[i]}" "$(envq "${FSQL_ENV_VALUES[i]}")"
                done
            } | priv "${as_root}" tee -a "${envfile}" >/dev/null
            log "${restart_cmd}"
            if confirm "Restart mysqld now to apply it?"; then
                if have_systemd; then
                    priv "${as_root}" systemctl restart mysql
                else
                    restart_mysqld_direct priv_as_root
                fi
                ok "mysqld restarted with the new reasoning config."
            else
                warn "Not restarted. The config won't take effect until you run: ${restart_cmd}"
                return 1
            fi
            ;;
        rhel)
            dropin_dir="/etc/systemd/system/mysql.service.d"
            dropin="${dropin_dir}/fractalsql-env.conf"
            restart_cmd="systemctl restart mysql"
            [[ "${as_root}" -eq 1 ]] || restart_cmd="sudo ${restart_cmd}"
            if [[ "${DRY_RUN}" -eq 1 ]]; then log "(--dry-run: not actually writing or restarting)"; return 0; fi
            priv "${as_root}" mkdir -p "${dropin_dir}"
            {
                echo "[Service]"
                for i in "${!FSQL_ENV_KEYS[@]}"; do
                    printf "Environment=%s=%s\n" "${FSQL_ENV_KEYS[i]}" "${FSQL_ENV_VALUES[i]}"
                done
            } | priv "${as_root}" tee "${dropin}" >/dev/null
            priv "${as_root}" systemctl daemon-reload
            log "${restart_cmd}"
            if confirm "Restart mysqld now to apply it?"; then
                priv "${as_root}" systemctl restart mysql
                ok "mysqld restarted with the new reasoning config."
            else
                warn "Not restarted. The config won't take effect until you run: ${restart_cmd}"
                return 1
            fi
            ;;
        darwin)
            warn "macOS (launchd/brew services) needs this set by hand: edit the mysql formula's launchd plist environment (brew services --help / 'brew info mysql') to add the FRACTALSQL_* variables printed above, then 'brew services restart mysql'. Not automated here -- launchd plist edits vary per Homebrew version."
            return 1
            ;;
    esac
}

# A cold-loading local model (for example, a large Ollama model pulled
# onto constrained hardware) can take minutes to produce its first
# answer, longer than the reasoning plugin's default HTTP timeout. These
# are the same values easy_install.ps1 applies on Windows.
offer_cold_start_timeout() {
    confirm "Local models can be slow to answer the first time while they load into memory or VRAM. Raise the reasoning HTTP timeout to handle that? It is applied with the mysqld restart below, which drops active connections." \
        || return 0
    env_set_raw FSQL_REASONING_HTTP_TIMEOUT_MS 330000
    env_set_raw FSQL_REASONING_HTTP_LOW_SPEED_SECS 300
}

phase_c_wizard() {
    # UDFs (sql/install_udf.sql) are server-global (mysql.func), no
    # database needed. Agent procedures (sql/install_agents.sql) are
    # ordinary stored procedures, which do need one: running
    # install_agents.sql with no database selected fails with
    # "ERROR 1046: No database selected". docs/getting-started.md's own
    # manual instructions already assume a pre-existing `mydb`; this
    # asks for the same thing rather than inventing a default database
    # name no one asked for.
    DATABASE="${DATABASE:-$(prompt "Target database for the agent stored procedures (must already exist; UDFs themselves don't need one)" "")}"
    [[ -n "${DATABASE}" ]] || die "a target database is required to register the agent procedures. Pass --database <name>."
    "${MYSQL_AS[@]}" -Nse "SHOW DATABASES LIKE '$(printf '%s' "${DATABASE}" | sed "s/'/''/g")';" | grep -qx "${DATABASE}" \
        || die "database '${DATABASE}' doesn't exist. Create it first (CREATE DATABASE ${DATABASE};), then re-run with --database ${DATABASE}."
    MYSQL_AS+=(-D "${DATABASE}")

    if [[ -z "${PROVIDER}" ]]; then
        log "Reasoning provider:"
        echo "  1) Local Ollama"
        echo "  2) Cloud / OpenAI-compatible endpoint"
        echo "  3) Skip: search-only install, configure reasoning later"
        local choice; choice="$(prompt "Choice" "1")"
        case "${choice}" in
            1) PROVIDER="ollama" ;;
            2) PROVIDER="openai-compatible" ;;
            *) PROVIDER="skip" ;;
        esac
    fi

    local plugin_so="${PLUGIN_DIR}/fractalsql-reasoning-http.so"

    case "${PROVIDER}" in
        ollama)
            HTTP_URL="${HTTP_URL:-$(prompt "Ollama chat URL" "http://localhost:11434/v1/chat/completions")}"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-oss:20b")}"
            HTTP_EMBED_URL="${HTTP_EMBED_URL:-$(prompt "Ollama embeddings URL" "http://localhost:11434/v1/embeddings")}"
            HTTP_EMBED_MODEL="${HTTP_EMBED_MODEL:-$(prompt "Embedding model" "nomic-embed-text")}"
            HTTP_THINK="${HTTP_THINK:-off}"
            HTTP_THINK_PROVIDER="${HTTP_THINK_PROVIDER:-ollama}"
            env_set REASONING_PLUGIN "${plugin_so}"
            env_set HTTP_URL "${HTTP_URL}"
            env_set HTTP_ALLOW_PLAINTEXT "1"
            env_set HTTP_MODEL "${HTTP_MODEL}"
            env_set HTTP_EMBED_URL "${HTTP_EMBED_URL}"
            env_set HTTP_EMBED_MODEL "${HTTP_EMBED_MODEL}"
            env_set HTTP_THINK "${HTTP_THINK}"
            env_set HTTP_THINK_PROVIDER "${HTTP_THINK_PROVIDER}"
            ;;
        openai-compatible)
            HTTP_URL="${HTTP_URL:-$(prompt "Chat completions URL" "")}"
            [[ -n "${HTTP_URL}" ]] || die "a URL is required for a cloud/OpenAI-compatible endpoint"
            HTTP_MODEL="${HTTP_MODEL:-$(prompt "Model" "gpt-4o-mini")}"
            [[ -n "${HTTP_TOKEN}" ]] || HTTP_TOKEN="$(prompt_secret "API token (masked, never logged)")"
            env_set REASONING_PLUGIN "${plugin_so}"
            env_set HTTP_URL "${HTTP_URL}"
            env_set HTTP_TOKEN "${HTTP_TOKEN}"
            env_set HTTP_MODEL "${HTTP_MODEL}"
            if [[ "${HTTP_URL}" != https://* ]]; then
                warn "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            fi
            ;;
        skip)
            log "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
            ;;
        *) die "unknown --provider '${PROVIDER}' (expected ollama, openai-compatible, or skip)" ;;
    esac

    if [[ "${PROVIDER}" == "ollama" ]]; then
        offer_cold_start_timeout
    fi

    local applied=1
    if [[ "${PROVIDER}" != "skip" ]]; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "About to set (mysqld environment):"
            for i in "${!FSQL_ENV_KEYS[@]}"; do
                if [[ "${FSQL_ENV_KEYS[i]}" == *HTTP_TOKEN* ]]; then
                    echo "  ${FSQL_ENV_KEYS[i]}=***"
                else
                    echo "  ${FSQL_ENV_KEYS[i]}=${FSQL_ENV_VALUES[i]}"
                fi
            done
            log "(--dry-run: not actually applying)"
        else
            apply_env_and_restart && applied=0 || applied=1
        fi
    fi

    log "Registering UDFs + agent procedures..."
    local already=0
    "${MYSQL_AS[@]}" -Nse "SELECT 1 FROM mysql.func WHERE name='fractal_edition';" 2>/dev/null | grep -q 1 && already=1
    if [[ "${already}" -eq 1 && "${FORCE_REINSTALL}" -ne 1 ]]; then
        confirm "fractal_edition() is already registered. Re-register UDFs/procedures against the currently staged plugin file?" \
            || die "Nothing to do. Re-run with --force-reinstall to skip this pause."
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log "(--dry-run: not actually running sql/install_udf.sql or sql/install_agents.sql)"
    else
        HERE_SQL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/sql"
        if [[ -f "${HERE_SQL}/install_udf.sql" ]]; then
            "${MYSQL_AS[@]}" < "${HERE_SQL}/install_udf.sql"
            "${MYSQL_AS[@]}" < "${HERE_SQL}/install_agents.sql"
        else
            die "sql/install_udf.sql not found next to this script and no repo checkout detected. Run this from an extracted release asset directory or a repo checkout."
        fi
        ok "UDFs + agent procedures registered."
    fi

    if [[ "${DRY_RUN}" -ne 1 ]]; then
        local ed ver
        ed="$("${MYSQL_AS[@]}" -Nse 'SELECT fractal_edition();')"
        ver="$("${MYSQL_AS[@]}" -Nse 'SELECT fractal_version();')"
        ok "fractal_edition() = ${ed}, fractal_version() = ${ver}"
        if [[ "${ver}" != "${INSTALL_VERSION}" ]]; then
            warn "That's not ${INSTALL_VERSION}, the version this script expected. The installed .so itself is out of date. Reinstall the current package from https://github.com/${REPO}/releases over this install to actually update the plugin file, then re-run this script."
        fi
        if [[ "${PROVIDER}" != "skip" && "${applied}" -eq 0 ]] \
            && confirm "Run a live reasoning smoke test (SELECT fractal_reason(CONNECTION_ID(), 'say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time."; then
            local reply; reply="$("${MYSQL_AS[@]}" -Nse "SELECT fractal_reason(CONNECTION_ID(), 'say ok');" 2>&1 || true)"
            echo "  ${reply}" | head -5
            if [[ "${reply}" == *ERROR* ]]; then
                warn "That failed. If it looks like a timeout on a slow/cold local model, see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            fi
        elif [[ "${PROVIDER}" != "skip" && "${applied}" -ne 0 ]]; then
            warn "Reasoning config wasn't applied (restart declined or unsupported on this OS), so skipping the smoke test. fractal_reason() will use whatever config mysqld already has."
        fi
    fi

    printf "\n${G}You're set up.${Z} Where next:\n"
    cat <<'EOF'
  - docs/starter-kits.md: industry-specific runnable examples
  - docs/api-agency.md: the 16 built-in agents, full reference
  - docs/composition-guide.md: build your own agent
  - Re-run this script anytime to switch providers or models. It's
    safe, but every change needs a mysqld restart to take effect.
EOF
}

# --- --uninstall ---------------------------------------------------------
uninstall_flow() {
    log "This will reset FRACTALSQL_* reasoning env vars and restart mysqld."
    if confirm "Reset reasoning env vars now?"; then
        local as_root=0; [[ "$(id -u)" -eq 0 ]] && as_root=1
        priv() { local skip="$1"; shift; if [[ "${skip}" -eq 1 ]]; then "$@"; else sudo "$@"; fi; }
        priv_as_root() { priv "${as_root}" "$@"; }
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: not actually resetting)"
        else
            case "${OS_FAMILY}" in
                debian)
                    for k in "${FSQL_ENV_ALL_KEYS[@]}"; do priv "${as_root}" sed -i "/^${k}=/d" /etc/default/mysql 2>/dev/null || true; done
                    if confirm "Restart mysqld now?"; then
                        if have_systemd; then priv "${as_root}" systemctl restart mysql; else restart_mysqld_direct priv_as_root; fi
                        ok "mysqld restarted."
                    fi
                    ;;
                rhel)
                    priv "${as_root}" rm -f /etc/systemd/system/mysql.service.d/fractalsql-env.conf
                    priv "${as_root}" systemctl daemon-reload
                    confirm "Restart mysqld now?" && { priv "${as_root}" systemctl restart mysql; ok "mysqld restarted."; }
                    ;;
                darwin) warn "Remove the FRACTALSQL_* entries from mysql's launchd plist by hand, then 'brew services restart mysql'." ;;
            esac
        fi
    fi

    if confirm "Also drop the fractalsql UDFs and agent procedures (sql/install_udf.sql defines the exact DROP list)?"; then
        if [[ "${DRY_RUN}" -eq 1 ]]; then
            log "(--dry-run: not actually dropping)"
        else
            "${MYSQL_AS[@]}" -Nse "SELECT CONCAT('DROP FUNCTION IF EXISTS ', name, ';') FROM mysql.func WHERE dl='fractalsql.so' OR dl='fractalsql.dylib';" \
                | "${MYSQL_AS[@]}"
            ok "UDFs dropped. Agent procedures (fractal_agent_*) aren't UDFs and aren't tracked in mysql.func -- drop them with: mysql < sql/install_agents.sql's own DROP PROCEDURE list, or DROP them by hand."
        fi
    fi

    case "${OS_FAMILY}" in
        debian) echo "  To remove the package: sudo apt remove fractalsql-mysql" ;;
        rhel)
            if [[ "${PKG_MGR}" == "zypper" ]]; then
                echo "  To remove the package: sudo zypper remove fractalsql-mysql"
            else
                echo "  To remove the package: sudo ${PKG_MGR} remove fractalsql-mysql"
            fi
            ;;
        darwin) echo "  To remove the files: rm ${PLUGIN_DIR}/fractalsql.so ${PLUGIN_DIR}/fractalsql-reasoning-http.so" ;;
    esac
}

# --- main ------------------------------------------------------------------
main() {
    detect_os
    detect_mysql
    resolve_mysql_as
    log "Targeting MySQL (plugin_dir ${PLUGIN_DIR})"

    if [[ "${UNINSTALL}" -eq 1 ]]; then
        uninstall_flow
        exit 0
    fi

    phase_b_install
    phase_c_wizard
}

main "$@"
