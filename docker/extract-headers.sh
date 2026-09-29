#!/bin/sh
# Extract (not install) the same-version mysql-community-devel rpm's C
# headers into /usr/include/mysql. Invoked by docker/Dockerfile.test;
# kept as a separate script file so no shell variable in it is ever
# touched by Dockerfile variable substitution. The rpm filename is
# looked up in the repo's directory listing because the
# release-number component ("mysql-community-devel-8.4.11-<REL>.el9
# .x86_64.rpm") is not derivable from the server version alone.
#
# The yum tree is organized by release LINE, not by literal major:
# LTS/feature releases live under mysql-<SUB>-community (e.g.
# mysql-9.7-community), but the 26.x line has no such per-major path
# (mysql-26.7-community 404s) -- it lives under
# mysql-innovation-community instead, which carries
# mysql-community-devel-26.7.0-1.el9.<arch>.rpm. The case below picks
# the line from the server's own version string, so the same script
# serves every matrix cell.
#
# Why extract rather than install: the devel rpm conflicts with the
# official image's mysql-community-server-minimal package (both ship
# /usr/bin/mysql_config and the client-plugins files), but
# mysql_config --cflags (already in the image, pointing at
# /usr/include/mysql) resolves once the headers land there.
set -eux
VER="$(mysqld --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
SUB="${VER%.*}"
ARCH="$(uname -m)"
case "$SUB" in
  26.*) REPO="mysql-innovation-community" ;;
  *)    REPO="mysql-${SUB}-community" ;;
esac
BASE="https://repo.mysql.com/yum/${REPO}/el/9/${ARCH}"
RPM="$(curl -fsSL "${BASE}/" | grep -oE "mysql-community-devel-${VER}-[0-9.]+\.el9\.${ARCH}\.rpm" | sort -u | head -n 1)"
if [ -z "$RPM" ]; then
  # The directory listing can lag behind the rolling tags' patch
  # releases (the listing showed 8.4.9 while the mysql:8.4 tag served
  # 8.4.11). The repo's repodata is authoritative, so fall back to
  # parsing the primary metadata the same way.
  PRIMARY="$(curl -fsSL "${BASE}/repodata/repomd.xml" | grep -oE 'href="repodata/[^"]*-primary\.xml\.gz"' | head -n 1 | sed 's/^href="//;s/"$//')"
  test -n "$PRIMARY"
  RPM="$(curl -fsSL "${BASE}/${PRIMARY}" | gunzip | grep -oE "mysql-community-devel-${VER}-[0-9.]+\.el9\.${ARCH}\.rpm" | sort -u | head -n 1)"
fi
test -n "$RPM"
curl -fsSLo /tmp/devel.rpm "${BASE}/${RPM}"
rpm2cpio /tmp/devel.rpm | cpio -idmu -D /
test -f /usr/include/mysql/mysql.h
rm -f /tmp/devel.rpm