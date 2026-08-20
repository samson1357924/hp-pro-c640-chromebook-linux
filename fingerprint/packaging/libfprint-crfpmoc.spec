# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Samson <https://github.com/samson1357924>
Name:           libfprint-crfpmoc
Version:        1.94.10
Release:        1%{?dist}
Summary:        Toolkit for fingerprint readers with ChromeOS Match-on-Chip support

License:        LGPL-2.1-or-later
URL:            https://gitlab.freedesktop.org/3v1n0/libfprint
Source0:        https://gitlab.freedesktop.org/3v1n0/libfprint/-/archive/56442591a5c302a906289f30988fb50fc3d82ed6/libfprint-56442591a5c302a906289f30988fb50fc3d82ed6.tar.gz
Source1:        60-cros-fp.rules
Source2:        crfpmoc-driver-overlay.tar.gz

BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  meson
BuildRequires:  ninja-build
BuildRequires:  pkgconfig(glib-2.0) >= 2.56.0
BuildRequires:  pkgconfig(gusb) >= 0.3.0
BuildRequires:  pkgconfig(pixman-1)
BuildRequires:  pkgconfig(gudev-1.0)
BuildRequires:  pkgconfig(json-glib-1.0)
BuildRequires:  pkgconfig(nss)
BuildRequires:  pkgconfig(openssl)
BuildRequires:  systemd-devel
BuildRequires:  gobject-introspection-devel

Provides:       libfprint = %{version}-%{release}
Provides:       libfprint%{?_isa} = %{version}-%{release}
Conflicts:      libfprint

%description
libfprint is an open source software library designed to make it easy for
application developers to add support for consumer fingerprint readers.
This package provides the crfpmoc driver for ChromeOS Match-on-Chip devices.

%package        devel
Summary:        Development files for %{name}
Requires:       %{name}%{?_isa} = %{version}-%{release}
Provides:       libfprint-devel = %{version}-%{release}
Conflicts:      libfprint-devel

%description    devel
The %{name}-devel package contains libraries and header files for
developing applications that use %{name}.

%prep
%autosetup -n libfprint-56442591a5c302a906289f30988fb50fc3d82ed6 -a 2
# The driver overlay ships crfpmoc-proto.c but upstream libfprint/meson.build
# only lists crfpmoc.c + crfpmoc-ec-transfer.c — add it idempotently.
sed -i "s|'drivers/crfpmoc/crfpmoc-ec-transfer.c',|'drivers/crfpmoc/crfpmoc-ec-transfer.c',\n        'drivers/crfpmoc/crfpmoc-proto.c',|" libfprint/meson.build

%build
%meson -Ddrivers=default -Dintrospection=true -Dgtk-examples=false -Ddoc=false
%meson_build

%install
%meson_install
install -D -p -m 0644 %{SOURCE1} %{buildroot}%{_udevrulesdir}/60-cros-fp.rules

%files
%license COPYING
%doc README.md
%{_libdir}/libfprint-2.so.*
%{_libdir}/girepository-1.0/FPrint-2.0.typelib
%{_udevrulesdir}/60-cros-fp.rules
%{_udevhwdbdir}/*

%files devel
%{_includedir}/libfprint-2/
%{_libdir}/libfprint-2.so
%{_libdir}/pkgconfig/libfprint-2.pc
%{_datadir}/gir-1.0/FPrint-2.0.gir

%changelog
* Sat Aug 15 2026 HP Pro c640 Linux Team <samson1357924@users.noreply.github.com> - 1.94.10-1
- Initial packaging for ChromeOS MoC (FPC1025 / Dratini)
