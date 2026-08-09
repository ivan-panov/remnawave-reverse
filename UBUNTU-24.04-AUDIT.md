# Ubuntu 24.04 audit

Build: `3.0.14`
Date: 2026-08-09

## Scope

The audit covered the custom Remnawave VLESS cascade and AmneziaWG 3.0 inbound integration, including Bash syntax, generated Xray JSON, policy routing, iptables TPROXY, systemd continuation after reboot, Docker Compose capabilities, API state/rollback, and removal paths.

## Corrected high-risk problems

1. **Policy-routing collisions and unsafe cleanup.** Fixed table/mark/priority values were replaced by dynamically selected free resources. Cleanup now requires integration ownership and never flushes a routing table merely because its number matches.
2. **Incorrect Xray rule order.** AWG/cascade rules are now inserted after explicit block/API guards but before existing generic catch-all routes, preventing an earlier `DIRECT` rule from bypassing the selected VLESS outbound.
3. **Host hardening interference.** The pinned AmneziaWG v5.24.0 launcher is invoked with `--no-tweaks`; the integration opens only its required UDP port instead of replacing UFW, Fail2Ban, SSH or sysctl policy globally.
4. **Non-transactional changes.** Profile assignment and state-file writes now roll back when a later step fails.
5. **Unsafe removal order.** Global installer removal is blocked until menu 13 and menu 12 integrations have been removed normally and their original profiles restored.
6. **Hard-coded Compose service.** The Remnawave Node service is discovered from Docker Compose labels; `NET_ADMIN` is patched and reverted for the actual service.
7. **DKMS in unsupported containers.** Automatic AWG installation is rejected in container virtualization such as LXC/OpenVZ; Ubuntu 24.04 KVM or bare metal is recommended.
8. **Conflict handling.** Added checks for AWG interface/config state, UDP/TProxy ports, client subnet overlap and stale/inactive installations.

## Validation status

All bundled shell files pass `bash -n`. The AWG3 wrapper, module-version gate, legacy-AWG2 safety block and generated runtime were also exercised with mocked tests. Generated systemd units pass `systemd-analyze verify`. Mock tests cover profile generation, API create/disable/enable/remove, Compose patching, routing allocation, state-write failure and rollback. The generated patch applies cleanly to the uploaded build.

A real Ubuntu 24.04/KVM, DKMS, reboot and end-to-end traffic test was not available in the audit environment. Treat this as a hardened release candidate and validate it on a snapshot before production use.
