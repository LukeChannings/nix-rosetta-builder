# dependencies
{
  nixos-generators,
  nixpkgs,
  lix-module,

  pkgs,
  lib,
  mount,
  umount,

  # configuration
  linuxSystem,
  onDemand, # enable launchd socket activation
}:
nixos-generators.nixosGenerate (
  let
    inherit (import ./constants.nix)
      linuxHostName
      linuxUser

      sshHostPrivateKeyFileName
      sshUserPublicKeyFileName

      debug
      ;
    imageFormat = "qcow-efi"; # must match `vmYaml.images.location`s extension

    sshdKeys = "sshd-keys";
    sshDirPath = "/etc/ssh";
    sshHostPrivateKeyFilePath = "${sshDirPath}/${sshHostPrivateKeyFileName}";

  in
  {
    format = imageFormat;

    modules = [
      lix-module.nixosModules.default
      {
        boot = {
          kernelParams = [ "console=tty0" ];

          loader = {
            efi.canTouchEfiVariables = true;
            systemd-boot.enable = true;
          };
        };

        documentation.enable = false;

        fileSystems = {
          "/".options = [
            "discard"
            "noatime"
          ];
          "/boot".options = [
            "discard"
            "noatime"
            "umask=0077"
          ];
        };

        networking.hostName = linuxHostName;

        nix = {
          package = lib.mkForce pkgs.lix;
          channel.enable = false;
          registry.nixpkgs.flake = nixpkgs;

          settings = {
            auto-optimise-store = true;
            experimental-features = [
              "flakes"
              "nix-command"
            ];
            trusted-users = [ linuxUser ];
          };
        };

        security = {
          sudo = {
            enable = debug;
            wheelNeedsPassword = !debug;
          };
        };

        services = {
          getty = lib.optionalAttrs debug { autologinUser = linuxUser; };

          logind = lib.optionalAttrs onDemand {
            extraConfig = ''
              IdleAction=poweroff
              IdleActionSec=3h
            '';
          };

          openssh = {
            enable = true;
            hostKeys = [ ]; # disable automatic host key generation

            settings = {
              HostKey = sshHostPrivateKeyFilePath;
              PasswordAuthentication = false;
            };
          };
        };

        system = {
          disableInstallerTools = true;
          stateVersion = "24.11";
        };

        # macOS' Virtualization framework's virtiofs implementation will grant any guest user access
        # to mounted files; they always appear to be owned by the effective UID and so access cannot
        # be restricted.
        # To protect the guest's SSH host key, the VM is configured to prevent any logins (via
        # console, SSH, etc) by default.  This service then runs before sshd, mounts virtiofs,
        # copies the keys to local files (with appropriate ownership and permissions), and unmounts
        # the filesystem before allowing SSH to start.
        # Once SSH has been allowed to start (and given the guest user a chance to log in), the
        # virtiofs must never be mounted again (as the user could have left some process active to
        # read its secrets).  This is prevented by `unitconfig.ConditionPathExists` below.
        systemd.services."${sshdKeys}" =
          let
            # Lima labels its virtiofs folder mounts counting up:
            # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/vz/vm_darwin.go#L568
            # So this suffix must match `vmYaml.mounts.location`s order:
            sshdKeysVirtiofsTag = "mount0";

            sshdKeysDirPath = "/var/${sshdKeys}";
            sshAuthorizedKeysUserFilePath = "${sshDirPath}/authorized_keys.d/${linuxUser}";
            sshdService = "sshd.service";

          in
          {
            before = [ sshdService ];
            description = "Install sshd's host and authorized keys";
            enableStrictShellChecks = true;
            path = [
              mount
              umount
            ];
            requiredBy = [ sshdService ];

            script =
              let
                sshAuthorizedKeysUserFilePathSh = lib.escapeShellArg sshAuthorizedKeysUserFilePath;
                sshAuthorizedKeysUserTmpFilePathSh = lib.escapeShellArg "${sshAuthorizedKeysUserFilePath}.tmp";
                sshHostPrivateKeyFileNameSh = lib.escapeShellArg sshHostPrivateKeyFileName;
                sshHostPrivateKeyFilePathSh = lib.escapeShellArg sshHostPrivateKeyFilePath;
                sshUserPublicKeyFileNameSh = lib.escapeShellArg sshUserPublicKeyFileName;
                sshdKeysDirPathSh = lib.escapeShellArg sshdKeysDirPath;
                sshdKeysVirtiofsTagSh = lib.escapeShellArg sshdKeysVirtiofsTag;

              in
              ''
                # must be idempotent in the face of partial failues

                mkdir -p ${sshdKeysDirPathSh}
                mount \
                  -t 'virtiofs' \
                  -o 'nodev,noexec,nosuid,ro' \
                  ${sshdKeysVirtiofsTagSh} \
                  ${sshdKeysDirPathSh}

                mkdir -p "$(dirname ${sshHostPrivateKeyFilePathSh})"
                (
                  umask 'go='
                  cp ${sshdKeysDirPathSh}/${sshHostPrivateKeyFileNameSh} ${sshHostPrivateKeyFilePathSh}
                )

                mkdir -p "$(dirname ${sshAuthorizedKeysUserTmpFilePathSh})"
                cp \
                  ${sshdKeysDirPathSh}/${sshUserPublicKeyFileNameSh} \
                  ${sshAuthorizedKeysUserTmpFilePathSh}
                chmod 'a+r' ${sshAuthorizedKeysUserTmpFilePathSh}

                umount ${sshdKeysDirPathSh}
                rmdir ${sshdKeysDirPathSh}

                # must be last so only now `unitConfig.ConditionPathExists` triggers
                mv ${sshAuthorizedKeysUserTmpFilePathSh} ${sshAuthorizedKeysUserFilePathSh}
              '';

            serviceConfig.Type = "oneshot";

            # see comments on this service and in its `script`
            unitConfig.ConditionPathExists = "!${sshAuthorizedKeysUserFilePath}";
          };

        users = {
          # console and (initial) SSH logins are purposely disabled
          # see: `systemd.services."${sshdKeys}"`
          allowNoPasswordLogin = true;

          mutableUsers = false;

          users."${linuxUser}" = {
            isNormalUser = true;
            extraGroups = lib.optionals debug [ "wheel" ];
          };
        };

        virtualisation.rosetta = {
          enable = true;

          # Lima's virtiofs label for rosetta:
          # https://github.com/lima-vm/lima/blob/0e931107cadbcb6dbc7bbb25626f66cdbca1f040/pkg/vz/rosetta_directory_share_arm64.go#L15
          mountTag = "vz-rosetta";
        };
      }
    ];

    system = linuxSystem;
  }
)
