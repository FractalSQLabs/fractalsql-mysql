%global         plugindir %{_libdir}/mysql/plugin
%global         sharedir  %{_datadir}/fractalsql-mysql

# Reference-only spec: scripts/package.sh (fpm-based, generic
# mysql-community-server dependency, no per-major fan-in -- the UDF ABI
# is stable across the supported MySQL majors, 8.4 LTS / 9.7 LTS / 26.7) is the
# actual build/package path used by CI (release.yml, install-test.yml)
# and documented in scripts/package.sh's own header. This file is kept
# for maintainers who prefer a native `rpmbuild` flow instead of fpm --
# it is not exercised by any workflow in this repo.

Name:           fractalsql-mysql
Version:        2.0.2
Release:        1%{?dist}
Summary:        FractalSQL UDF for MySQL (8.4 LTS / 9.7 LTS / 26.7)

License:        Apache-2.0
URL:            https://github.com/FractalSQLabs/fractalsql-mysql
Source0:        fractalsql-mysql-%{version}.tar.gz

# mysql-community-devel supplies mysql.h (headers only are needed: a
# UDF does not link against a server import lib). mysql-community-server
# is the Oracle repo's (repo.mysql.com) package, matching
# scripts/package.sh's runtime dependency below; EL's own archive has
# not carried a current MySQL server major since 8.0 went EOL.
BuildRequires:  gcc, make, mysql-community-devel
Requires:       mysql-community-server
Requires:       libcurl.so.4()(64bit)

%description
fractalsql-mysql registers the fractal_search() UDF, a Stochastic
Fractal Search optimizer that returns JSON top-k matches for a query
vector against an inline corpus, plus the full Discovery/Vector/
Cognition/Text-to-SQL/Agency/Enterprise-activation tier surface (see
docs/features.md). Pure-C vendored core, no LuaJIT runtime dependency.
The bundled fractalsql-reasoning-http.so plugin (Cognition/Text-to-SQL/
Vectorizer/Agency tiers) dynamically links libcurl at runtime.

%prep
%setup -q

%build
# The .so is produced out-of-band by build.sh on a Docker builder
# (glibc-pinned per PROFILE, see build.sh's own header); this spec
# just stages the already-built artifact.
test -f dist/amd64/fractalsql.so

%install
install -Dm0755 dist/amd64/fractalsql.so \
    %{buildroot}%{plugindir}/fractalsql.so
install -Dm0755 include/linux-x86_64/fractalsql-reasoning-http.so \
    %{buildroot}%{plugindir}/fractalsql-reasoning-http.so
install -Dm0644 sql/install_udf.sql \
    %{buildroot}%{sharedir}/install_udf.sql
install -Dm0644 sql/install_agents.sql \
    %{buildroot}%{sharedir}/install_agents.sql

%files
%license LICENSE
%doc THIRD-PARTY-NOTICES.md
%{plugindir}/fractalsql.so
%{plugindir}/fractalsql-reasoning-http.so
%{sharedir}/install_udf.sql
%{sharedir}/install_agents.sql

%changelog
* Tue Sep 23 2026 FractalSQLabs - 2.0.0-1
- Full v2.0.0 port to MySQL (8.4 LTS / 9.7 LTS / 26.7): Discovery/Vector/
  Cognition/Text-to-SQL/Vectorizer/Agency/Enterprise-activation tiers,
  plus 10 new v2.0.25-core analytics/vector primitives as UDFs
  (change-point detection, periodogram, SimHash state fingerprint,
  streaming cycle detection, TDA persistence, k-subset allocation,
  Lp distance, int8/binary quantization, Hamming distance), agent
  loop-detection rewrite over real state fingerprints, JSON_VALUE
  boolean-contract fix in shipped procedures.
  Single generic package (no per-major split -- the UDF ABI is stable
  across all supported majors), Apache-2.0, no LuaJIT.
* Sat Apr 18 2026 FractalSQLabs - 1.0.0-1
- Initial Factory-standardized release.