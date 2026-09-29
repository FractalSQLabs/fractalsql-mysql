# syntax=docker/dockerfile:1.7
#
# fractalsql-mysql Docker build: pure-C, vendored core archive,
# zero-dependency posture (no LuaJIT anywhere in this path).
#
# One fractalsql.so covers every supported MySQL major (8.4 LTS,
# 9.7 LTS, and 26.7).
# The UDF ABI (UDF_INIT / UDF_ARGS / MYSQL_ERRMSG_SIZE, bool
# xxx_init/xxx/xxx_deinit; MySQL 8.0+ replaced my_bool with bool) has
# been stable across all of them, so this Dockerfile only needs one
# build stage per (arch, libc-profile) cell.
#
# Build artifact (collected in the `export` stage, emitted to the host
# via `docker buildx --output type=local,dest=...`):
#   /fractalsql.so           (glibc 2.34)
#
# musl/Alpine is NOT a supported build target for this repo's shipped
# .so: build.sh drives the modern glibc-2.34 profile only, against the
# core archive vendored under include/linux-<arch>/.
#
# Usage:
#   DOCKER_BUILDKIT=1 docker buildx build \
#     --platform linux/amd64 \
#     --target export \
#     --output type=local,dest=./dist/amd64 \
#     --build-arg CORE_VARIANT=community-minimal-c \
#     -f docker/Dockerfile .
#
# build.sh drives this for amd64/arm64.

ARG BASE_IMAGE=rockylinux:9
ARG GLIBC_CEILING=34
ARG LIBC_KIND=glibc
ARG SIZE_CEILING_BYTES=3145728

# Demo-stage base tag. Declared here (before the first FROM, alongside
# the other global ARGs): an ARG used in a FROM line must be global --
# a stage-local ARG (declared mid-file) is not visible to later FROM
# lines, and `FROM mysql:${DEMO_MAJOR}` would parse as the invalid
# stage name "mysql:".
ARG DEMO_MAJOR=8.4

# Vendored core archive variant. Default "community-sovereign-c" is the
# modern glibc-2.34 build from the vendored core release drop in
# include/, a superset of "community-minimal-c" (confirmed via `nm`:
# exports every minimal-tier symbol plus the v2 sovereign-tier
# additions this repo's UDF layer links against, including
# fsql_dimension_*, fsql_optimize_portfolio*, fsql_vascular_network,
# fsql_cortical_folding, fsql_nerve_plexus_metric, and
# fsql_morphological_complexity).
ARG CORE_VARIANT=community-sovereign-c

ARG EXT_CFLAGS="-D_GLIBCXX_USE_CXX11_ABI=0 -ffunction-sections -fdata-sections -fvisibility=default"
ARG EXT_LDFLAGS="-static-libgcc -Wl,--gc-sections -Wl,--strip-all -Wl,--exclude-libs,ALL"

# --------------------------------------------------------------------
# Stage: builder. mysql-community-devel for UDF headers (mysql.h),
# vendored core .a for the SFS implementation.
# --------------------------------------------------------------------
FROM ${BASE_IMAGE} AS builder
# Headers only are needed (a UDF never calls server-exported symbols,
# so no server import lib is required), but mysql-community-devel is
# the only package carrying mysql.h. It comes from Oracle's own yum
# repo (a direct repo file, not the mysql-community-release noarch rpm:
# that rpm's default-enabled repo entry is the EOL 8.0 line, and its
# 8.4/9.x repo-path entries vary by release package version; the
# 26.x line lives under the mysql-innovation-community repo
# name instead). EL's distro
# archives stopped carrying a current MySQL server major when 8.0 went
# EOL. mysql_config ships inside the same rpm and is what build.sh's
# $(mysql_config --cflags) resolves against. gpgcheck=0 is acceptable
# here because the artifact gate below (assert_so.sh) constrains what
# actually ships, and pinning the repo lets dnf's content checks do the
# rest; the .so is what gets shipped, not these headers.
RUN set -eux; \
    # Exactly one $basearch in the repo file: dnf substitutes it. A doubled
    # $$basearch leaks into the file verbatim and dnf's left-to-right
    # substitution then matches only the inner $basearch, yielding a broken
    # "$x86_64" URL (404 at build time); a backslash-escaped \$basearch
    # leaks the backslash the same way ("\x86_64"). The builder image has
    # no ARG/ENV named basearch, so Docker build leaves the bare $basearch
    # alone and the single-quoted printf passes it through verbatim.
    printf '[mysql-community-el9]\nname=MySQL Community Server (Oracle repo, el9)\nbaseurl=https://repo.mysql.com/yum/mysql-8.4-community/el/9/$basearch/\nenabled=1\ngpgcheck=0\n' > /etc/yum.repos.d/mysql-community-el9.repo; \
    dnf install -y --setopt=install_weak_deps=0 \
        gcc gcc-c++ make binutils file \
        mysql-community-devel \
 && dnf clean all

WORKDIR /build
COPY src/                /build/src/
COPY include/            /build/include/
COPY docker/assert_so.sh /build/docker/assert_so.sh

ARG EXT_CFLAGS
ARG EXT_LDFLAGS
ARG SIZE_CEILING_BYTES
ARG GLIBC_CEILING
ARG LIBC_KIND
ARG CORE_VARIANT

# Core archives are vendored per-arch under include/linux-<uname-m>/
# (include/linux-x86_64/, include/linux-aarch64/), so a single
# Dockerfile works for both `docker buildx --platform
# linux/amd64` and `linux/arm64` via `uname -m` inside the builder stage.
RUN ARCH=$(uname -m) \
 && CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a" \
 && test -f "/build/${CORE_A}" \
    || (echo "ERROR: vendored core archive missing: ${CORE_A}" >&2 \
        && echo "  Re-deploy the vendored core release drop into include/," >&2 \
        && echo "  which restores the archive together with .artifacts.sha256." >&2 \
        && exit 1)

RUN set -eux; \
    ARCH=$(uname -m); \
    CORE_A="include/linux-${ARCH}/libfractalsql-${CORE_VARIANT}.a"; \
    MYSQL_CFLAGS="$(mysql_config --cflags 2>/dev/null || echo -I/usr/include/mysql)"; \
    gcc -Wall -Wextra -O3 -fPIC \
        -Iinclude $MYSQL_CFLAGS \
        ${EXT_CFLAGS} \
        -shared -o /fractalsql.so \
        src/fractalsql.c \
        src/fractalsql_parse.c \
        src/fractalsql_session.c \
        src/fractalsql_vector.c \
        src/fractalsql_cognition.c \
        src/fractalsql_textsql.c \
        src/fractalsql_enterprise.c \
        "/build/${CORE_A}" \
        -lm -lpthread -ldl \
        ${EXT_LDFLAGS}; \
    sh /build/docker/assert_so.sh /fractalsql.so \
        "${SIZE_CEILING_BYTES}" "${GLIBC_CEILING}" "${LIBC_KIND}"

# --------------------------------------------------------------------
# Export stage: scratch, so `buildx --output=local` drops just the .so.
# --------------------------------------------------------------------
FROM scratch AS export
COPY --from=builder /fractalsql.so /fractalsql.so

# --------------------------------------------------------------------
# Demo stage: a RUNNABLE MySQL server with the UDFs already
# registered, for docker-compose.yml. Every stage above this line only
# ever hands raw .so files to the host (buildx --output=local); this is
# the first stage in this file you can actually `docker run`.
#
# Pinned to MySQL 8.4 (the LTS major) since this is a fresh eval
# environment people will keep around, not an existing cluster to
# version-match. The 9.7 and 26.7 lines work identically (swap the
# FROM line or build with --build-arg DEMO_MAJOR=9 or 26 -- the
# official image tags, since mysql:9.0 pins the EOL 9.0 release).
#
# Turnkey end-state for `docker compose up -d` (no flags):
#   * MySQL 8.4 running, DB fractalsql_demo, with the fractalsql UDF
#     set already registered (sql/install_udf.sql run as an
#     entrypoint-initdb script).
#   * The `ollama` compose service is up by default with NO model
#     pulled (model download is user-initiated, via the `pull-model`
#     compose profile).
#   * Every demo is in /demo/ and runnable on demand via
#     `mysql -uroot -pfractalsql fractalsql_demo < /demo/<demo>.sql`.
#
# A real MySQL PLUGIN (`INSTALL SONAME`, a daemon-plugin-style GLOBAL
# system variable read from my.cnf) was considered and rejected in
# favor of the design below. MySQL's plugin loader
# requires a daemon plugin's declared interface version to match the
# running server's expectations, and a daemon plugin is not part of
# this repo's UDF-ABI surface -- unlike every CREATE FUNCTION ...
# SONAME UDF in this library, which the stable UDF ABI already makes
# major/patch-independent.
#
# fractal_reason()/fractal_embed() (src/fractalsql_cognition.c) are
# instead configured via mysqld's PROCESS ENVIRONMENT, read once on
# first use: FRACTALSQL_REASONING_PLUGIN / FRACTALSQL_HTTP_URL /
# FRACTALSQL_HTTP_TOKEN / FRACTALSQL_HTTP_MODEL /
# FRACTALSQL_HTTP_EMBED_URL / FRACTALSQL_HTTP_EMBED_MODEL, set below
# via `environment:` in docker-compose.yml, pointing at the `ollama`
# service. See docs/reasoning-setup.md for the full configuration walkthrough.
# --------------------------------------------------------------------
FROM mysql:${DEMO_MAJOR} AS demo
# microdnf (this image is Oracle Linux 9 based, not Debian): python3
# for the bench/ head-to-head runs'
# python-based flows and libcurl for fractalsql-reasoning-http.so
# (bundled below), which dynamically links libcurl.so.4. Without it,
# fsql_load_reasoning's dlopen fails silently from a plain UDF's
# perspective: the UDF ABI has no per-call custom error message path,
# so fractal_reason/fractal_embed/fractal_t2s_generate all just return
# NULL with a generic error instead of surfacing
# "libcurl.so.4: cannot open shared object file".
RUN microdnf install -y \
        python3 \
        libcurl \
 && microdnf clean all

COPY --from=builder /fractalsql.so /usr/lib64/mysql/plugin/fractalsql.so

# Bundled reasoning plugin (vendored prebuilt .so from include/). Select
# the right arch via `uname -m` the same way the builder stage does, so
# this image builds on both linux/amd64 and linux/arm64. include/
# carries the plugin for every supported platform (linux-x86_64,
# linux-aarch64, darwin-arm64, darwin-x86_64; windows-x86_64 ships a
# .dll via the MSI path, not used here).
COPY include/linux-x86_64/fractalsql-reasoning-http.so  /usr/lib64/mysql/plugin/fractalsql-reasoning-http.x86_64.so
COPY include/linux-aarch64/fractalsql-reasoning-http.so /usr/lib64/mysql/plugin/fractalsql-reasoning-http.aarch64.so
RUN set -e \
 && ARCH=$(uname -m) \
 && mv "/usr/lib64/mysql/plugin/fractalsql-reasoning-http.${ARCH}.so" \
        /usr/lib64/mysql/plugin/fractalsql-reasoning-http.so \
 && rm -f /usr/lib64/mysql/plugin/fractalsql-reasoning-http.*.so

# docker-entrypoint-initdb.d scripts run once, on first container start,
# in lexical order, against the DB named by MYSQL_DATABASE. This
# registers every UDF in sql/install_udf.sql (CREATE FUNCTION ...
# SONAME 'fractalsql.so') the same way `mysql -uroot -p < install_udf.sql`
# does for a manual install. install_agents.sql runs second (11- prefix,
# after 10-) since its 15 stored procedures call base-tier functions
# install_udf.sql just registered.
COPY sql/install_udf.sql    /docker-entrypoint-initdb.d/10-fractalsql.sql
COPY sql/install_agents.sql /docker-entrypoint-initdb.d/11-fractalsql-agents.sql

# bench/ head-to-head tester. requirements-equivalent deps come from
# bench/tester/package.json (Node, not Python, for this repo's
# existing bench harness). Install at image build time so the layer
# caches independently of source changes.
COPY bench/ /bench/

# Every demo, runnable on demand via
#   mysql -uroot -pfractalsql fractalsql_demo < /demo/<demo>.sql
# Not run at init: reasoning
# demos are inert without a pulled model, and every demo is re-runnable.
COPY demo/ /demo/