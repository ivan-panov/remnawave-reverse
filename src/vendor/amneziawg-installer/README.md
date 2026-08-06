# Pinned AmneziaWG 3.0 installer launcher

This directory contains a small launcher for the upstream project:

- Repository: `bivlked/amneziawg-installer`
- Release: `v5.24.0`
- Immutable commit: `2c86966f59d54c0fd0bcf66639c537558a1a0c25`

The launcher downloads `install_amneziawg.sh` from the immutable commit over HTTPS and passes through all CLI arguments.

For this Remnawave integration, a new installation is allowed only on x86_64 with Linux kernel 6.7 or newer. After installation, the kernel module version is verified with `modinfo`; TPROXY is enabled only when the module version begins with `3.`.

The upstream installer itself may use an AmneziaWG 2.0 fallback on older kernels or some ARM paths. This integration intentionally blocks those paths so the menu item really means AmneziaWG 3.0.
