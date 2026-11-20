{
  lib,
  fetchurl,
  writeScript,
  writeShellScriptBin,
  writeText,
  qemu,
  runCommand,
  p7zip,
  libguestfs-with-appliance,
  chntpw,
  openssh,

  OVMF,
  efiFirmware ? OVMF.fd.firmware,

  qemu-common,
  customQemu ? null,
}:

let
  qemuBin = if (customQemu != null) then customQemu else (qemu-common.qemuBinary qemu);

  sshArgs = "-o WarnWeakCrypto=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes -i ${./test-windows-key}";

  # Upload cross-compiled nix-cli binaries to a running Windows VM via SSH/SCP.
  # Extra DLLs (e.g. stub-shell32) are copied into the bin directory so the
  # Windows DLL loader finds them next to nix.exe.
  uploadNixCli =
    {
      nix-cli,
      extraDlls ? [ ],
      ssh,
      scp,
    }:
    ''
      # Dereference symlinks (DLLs are symlinks into the Nix store)
      NIX_BIN=$(mktemp -d)
      cp -rL --no-preserve=mode ${nix-cli}/bin "$NIX_BIN/nix-bin"
      ${lib.concatMapStringsSep "\n" (dll: ''
        cp -L ${dll}/bin/*.dll "$NIX_BIN/nix-bin/"
      '') extraDlls}

      ${ssh} -n "mkdir C:\nix" 2>/dev/null || true
      ${scp} -r "$NIX_BIN/nix-bin" Administrator@127.0.0.1:C:/nix/bin
      rm -rf "$NIX_BIN"
    '';
in

rec {
  validationIso = fetchurl {
    url = "https://software-static.download.prss.microsoft.com/dbazure/998969d5-f34g-4e03-ac9d-1f9786c66749/26100.7705.260126-1049.ge_release_svc_prod3_amd64fre_en-us_VALIDATIONOS.iso";
    hash = "sha256-4jE5BuZewoLeTcOU6uqR7261DQJtQDR7t6QTbW/VXyQ=";
    meta.license = lib.licenses.unfree;
  };

  startupScript =
    commands:
    writeText "startnet.valos.cmd" ''
      @ECHO OFF
      IF NOT DEFINED StartupRun (
        ${commands}
        SET StartupRun=1
      )
    '';

  # Extract and configure the ValidationOS VHDX from the ISO.
  # Injects a startup script and patches the registry so Winlogon runs it.
  makeValidationVhdx =
    startupCommands:
    runCommand "ValidationOS.vhdx"
      {
        nativeBuildInputs = [
          p7zip
          libguestfs-with-appliance
          chntpw
        ];
        meta.license = lib.licenses.unfree;
      }
      ''
        7z x ${validationIso} ValidationOS.vhdx
        mv ValidationOS.vhdx $out

        export HOME=$(mktemp -d)
        guestfish -a $out -m /dev/sda4 upload ${startupScript startupCommands} /Windows/System32/startnet.valos.cmd
        guestfish -a $out -m /dev/sda4 download /Windows/System32/config/SOFTWARE SOFTWARE
        echo "y" | reged -I SOFTWARE "HKEY_LOCAL_MACHINE\SOFTWARE" ${./Winlogon.reg} || true # reged exits 2 for successful writes!
        guestfish -a $out -m /dev/sda4 upload SOFTWARE /Windows/System32/config/SOFTWARE
      '';

  # Pre-built ValidationOS VHDX with firewall disabled and SSH key installed.
  validationVhdx = makeValidationVhdx ''
    netsh.exe advfirewall set allprofiles state off
    echo ${lib.trim (builtins.readFile ./test-windows-key.pub)} > C:\ProgramData\ssh\administrators_authorized_keys
  '';

  qemuCommandWindows = ''
    ${qemuBin} \
      -m 512 \
      -netdev user,id=net0,hostfwd=tcp::2222-:22 \
      -device e1000e,netdev=net0 \
      -drive if=pflash,format=raw,unit=0,readonly=on,file=${efiFirmware} \
      ''${diskImage:+-hda $diskImage} \
      $QEMU_OPTS
  '';

  # Boot ValidationOS and run commands via SSH.
  runWithWindowsSsh =
    name: command:
    runCommand name
      {
        SSH_USERNAME = "Administrator";
        SSH_PORT = 2222;
        MAX_WAIT = 30;
        # Not `-nographic`, which puts the serial console on stdio, and
        # makes the build's stdout non-blocking, so later writes to it
        # (`cat $out`) can fail with `EAGAIN`.
        QEMU_OPTS = [
          "-display"
          "none"
        ];

        requiredSystemFeatures = [ "kvm" ];
        nativeBuildInputs = [
          qemu
          openssh
        ];
        buildInputs = [ OVMF.fd ];
      }
      ''
        cp "${validationVhdx}" ValidationOS.vhdx
        chmod u+w ValidationOS.vhdx

        export diskImage=$PWD/ValidationOS.vhdx
        set -x
        ${lib.trim qemuCommandWindows} &
        set +x
        QEMU_PID=$!

        SSH="ssh ${sshArgs} -p $SSH_PORT $SSH_USERNAME@127.0.0.1"
        SCP="scp ${sshArgs} -P $SSH_PORT"

        echo "Waiting for SSH..."
        for i in $(seq 1 "$MAX_WAIT"); do
          if $SSH -o ConnectTimeout=1 -n >/dev/null 2>&1; then
            echo "SSH is up"
            break
          fi
          sleep 1
        done

        if [ "$i" -eq "$MAX_WAIT" ]; then
          echo "SSH never came up" >&2
          kill $QEMU_PID || true
          exit 1
        fi

        ${command}

        kill $QEMU_PID || true
      '';

  # Cross-build Nix for Windows, boot ValidationOS, and run a test build.
  nixWindowsTest =
    {
      nix-cli,
      extraDlls ? [ ],
    }:
    runWithWindowsSsh "nix-windows-test" ''
      set -x

      ${uploadNixCli {
        inherit nix-cli extraDlls;
        ssh = "$SSH";
        scp = "$SCP";
      }}

      cat > hello.nix <<'NIXEOF'
      derivation {
        name = "hello";
        system = "x86_64-windows";
        builder = "cmd.exe";
        args = [ "/c" "echo hello > %out%" ];
      }
      NIXEOF

      $SCP hello.nix Administrator@127.0.0.1:C:/nix/hello.nix
      # Keep stdout, the built paths, apart from the `--debug` logging on
      # stderr, so they don't run together; then put each on its own
      # `OUT=` line at the end of the log. `tee` so the logging streams.
      exec 3> stdout
      $SSH -n "cd C:\\nix && bin\\nix.exe --debug build -f hello.nix --print-out-paths --no-link -L --extra-experimental-features nix-command" 2>&1 >&3 3>&- | tee $out >&2 || true
      exec 3>&-
      sed 's/^/OUT=/' stdout | tee -a $out
    '';

  # Boot ValidationOS and run one of Nix's cross-built unit test
  # executables, e.g. `nix-util-tests`, with its test data. Like
  # `nixWindowsTest`, this records the log whether or not the tests pass,
  # with the exit code on the last line.
  nixWindowsUnitTest =
    {
      tests,
      data,
      extraDlls ? [ ],
    }:
    runWithWindowsSsh "${tests.pname}-windows" ''
      set -x

      # Dereference symlinks (DLLs are symlinks into the Nix store)
      STAGING=$(mktemp -d)
      cp -rL --no-preserve=mode ${tests}/bin "$STAGING/bin"
      ${lib.concatMapStringsSep "\n" (dll: ''
        cp -L ${dll}/bin/*.dll "$STAGING/bin/"
      '') extraDlls}
      cp -rL --no-preserve=mode ${data} "$STAGING/data"

      $SSH -n "mkdir C:\\tests" 2>/dev/null || true
      $SCP -r "$STAGING/bin" Administrator@127.0.0.1:C:/tests/bin
      $SCP -r "$STAGING/data" Administrator@127.0.0.1:C:/tests/data
      rm -rf "$STAGING"

      # The default shell for OpenSSH on Windows is `cmd.exe`.
      # `tee` so the log streams as the tests run.
      exitCode=0
      $SSH -n "mkdir C:\\tests\\home && set \"HOME=C:\\tests\\home\"&& set \"_NIX_TEST_UNIT_DATA=C:\\tests\\data\"&& C:\\tests\\bin\\${tests.pname}.exe" 2>&1 | tee $out || exitCode=''${PIPESTATUS[0]}
      echo "EXIT=$exitCode" | tee -a $out
    '';

  # Inject Nix binaries into a ValidationOS VHDX using guestfish (no VM needed).
  # Produces a launcher script that boots the pre-configured image with a GUI.
  nixWindowsImage =
    {
      nix-cli,
      extraDlls ? [ ],
    }:
    runCommand "nix-windows"
      {
        nativeBuildInputs = [ libguestfs-with-appliance ];
        meta.license = lib.licenses.unfree;
      }
      ''
            cp "${validationVhdx}" ValidationOS.vhdx
            chmod u+w ValidationOS.vhdx

            # Dereference symlinks and collect all binaries into a staging directory.
            mkdir -p staging/nix/bin
            cp -rL --no-preserve=mode ${nix-cli}/bin/* staging/nix/bin/
            ${lib.concatMapStringsSep "\n" (dll: ''
              cp -L ${dll}/bin/*.dll staging/nix/bin/
            '') extraDlls}

            # Copy into the VHDX via guestfish.
            export HOME=$(mktemp -d)
            guestfish -a ValidationOS.vhdx -m /dev/sda4 mkdir-p /nix/bin
            for f in staging/nix/bin/*; do
              guestfish -a ValidationOS.vhdx -m /dev/sda4 upload "$f" "/nix/bin/$(basename $f)"
            done
            guestfish -a ValidationOS.vhdx -m /dev/sda4 upload ${./demo.nix} /demo.nix

            mkdir -p $out/bin $out/share
            mv ValidationOS.vhdx $out/share/

            cat > $out/bin/nix-windows <<'SCRIPT'
        #!/usr/bin/env bash
        set -euo pipefail

        WORKDIR="''${1:-.}"
        mkdir -p "$WORKDIR"
        cd "$WORKDIR"

        cp STORE_PATH/share/ValidationOS.vhdx ValidationOS.vhdx
        chmod u+w ValidationOS.vhdx

        echo "Starting ValidationOS with Nix..."
        echo "SSH: ssh SSH_ARGS -p 2222 Administrator@127.0.0.1"
        echo "Nix: C:\nix\bin\nix.exe"
        echo ""

        QEMU_BIN \
          -m 512 \
          -netdev user,id=net0,hostfwd=tcp::2222-:22 \
          -device e1000e,netdev=net0 \
          -drive if=pflash,format=raw,unit=0,readonly=on,file=EFI_FIRMWARE \
          -hda $PWD/ValidationOS.vhdx
        SCRIPT
            substituteInPlace $out/bin/nix-windows \
              --replace-fail STORE_PATH $out \
              --replace-fail SSH_ARGS '${sshArgs}' \
              --replace-fail QEMU_BIN '${qemuBin}' \
              --replace-fail EFI_FIRMWARE '${efiFirmware}'
            chmod +x $out/bin/nix-windows
      '';

  # Boot ValidationOS with GUI, upload Nix, and let the user interact.
  interactiveWindows =
    {
      nix-cli,
      extraDlls ? [ ],
    }:
    writeShellScriptBin "interactive-windows-nix" ''
      set -euo pipefail

      WORKDIR="''${1:-.}"
      mkdir -p "$WORKDIR"
      cd "$WORKDIR"

      cp "${validationVhdx}" ValidationOS.vhdx
      chmod u+w ValidationOS.vhdx

      export diskImage=$PWD/ValidationOS.vhdx

      SSH="${openssh}/bin/ssh ${sshArgs} -p 2222 Administrator@127.0.0.1"
      SCP="${openssh}/bin/scp ${sshArgs} -P 2222"

      echo "Starting ValidationOS VM..."
      echo "Nix will be uploaded via SSH once Windows boots."
      echo ""
      echo "Once booted, Nix will be available at C:\nix\bin\nix.exe"
      echo "Press Ctrl-C to stop the VM."

      export QEMU_OPTS=""
      ${lib.trim qemuCommandWindows} &
      QEMU_PID=$!
      trap "kill $QEMU_PID 2>/dev/null || true" EXIT

      echo "Waiting for SSH..."
      for i in $(seq 1 30); do
        if $SSH -o ConnectTimeout=1 -n >/dev/null 2>/dev/null; then
          echo "SSH is up - uploading Nix..."
          break
        fi
        sleep 1
      done

      if [ "$i" -eq 30 ]; then
        echo "SSH never came up" >&2
        exit 1
      fi

      ${uploadNixCli {
        inherit nix-cli extraDlls;
        ssh = "$SSH";
        scp = "$SCP";
      }}

      echo ""
      echo "Nix has been installed to C:\nix\bin"
      echo "You can SSH in with: ssh ${sshArgs} -p 2222 Administrator@127.0.0.1"
      echo ""

      wait $QEMU_PID
    '';
}
