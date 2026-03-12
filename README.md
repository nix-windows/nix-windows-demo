# Nix on Windows Demo

Builds a [Windows ValidationOS](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/validation-os-overview)
VM image with a cross-compiled [Nix](https://github.com/puffnfresh/nix/tree/windows-integration)
package manager pre-installed. No Windows license or installation required --
ValidationOS is a free minimal Windows environment intended for testing.

## Quick start

```
NIXPKGS_ALLOW_UNFREE=1 nix run --impure
```

This builds a ValidationOS VHDX with Nix baked in and boots it in QEMU. The
build is deterministic -- no VM is started during the build, files are injected
directly into the disk image using guestfish.

Once the VM is running, you can SSH in and run Nix:

```
ssh -o WarnWeakCrypto=no -o IdentitiesOnly=yes -i windows/test-windows-key -p 2222 Administrator@localhost "C:\nix\bin\nix-build C:\demo.nix"
```

```
ssh -o WarnWeakCrypto=no -o IdentitiesOnly=yes -i windows/test-windows-key -p 2222 Administrator@localhost "more C:\ProgramData\nix\store\z2cz5hvkhdp2zf7a2zhnvjv99c0xhw1x-hello"
```

The demo derivation (`C:\demo.nix`) runs `echo Hello` via `cmd.exe` and writes
the output to the Nix store.

## How it works

### ValidationOS

ValidationOS is a lightweight (~1GB) Windows image from Microsoft that boots
in seconds. It runs a minimal Windows PE environment with SSH pre-configured.
The VHDX is extracted from an ISO, then customised offline using guestfish and
chntpw to:

- Inject a startup script that disables the firewall and configures SSH keys
- Patch the Winlogon registry so `cmd.exe` opens in `C:\nix\bin`

### stub-shell32

ValidationOS is missing `shell32.dll`, which Nix needs for
`SHGetKnownFolderPath` (to locate `AppData`, `ProgramData`, etc.). Rather than
patching Nix, this repo includes a minimal cross-compiled stub DLL
(`windows/stub-shell32/`) that implements this function by reading the
corresponding environment variables (`LOCALAPPDATA`, `APPDATA`,
`ProgramData`). The stub is placed next to `nix.exe` so the Windows DLL loader
picks it up first.

### Cross-compilation

Nix and the stub DLL are cross-compiled from Linux using MinGW
(`pkgsCross.mingwW64`). The entire build -- including disk image preparation --
runs on Linux with no Windows tooling required.
