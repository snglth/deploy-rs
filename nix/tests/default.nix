{ pkgs
, inputs
, lib
, ...
}:

let
    inherit (pkgs) system;

    sharedModule = {
      virtualisation.graphics = false;
      virtualisation.msize = 5120;
      virtualisation.cores = 5;
      virtualisation.writableStore = true;
      virtualisation.writableStoreUseTmpfs = true;

      nix.extraOptions = ''
        experimental-features = nix-command flakes
      '';

      nix.trustedUsers = [ "root" "@wheel" ];
    };
in {
  simple-deployment = let
    nodes = {
      server = _: {
        services.openssh.enable = true;
        imports = [ sharedModule ];

        virtualisation.useBootLoader = true;
        virtualisation.useNixStoreImage = true;
        virtualisation.bootDevice = "/dev/vda";
      };

      client = _: sharedModule;
    };

    # TODO: client # error: cannot add path '/nix/store/4rd3hzbjjiwpm91a87qb4qk2ppqsgnj9-relaxedsandbox.nix' because it lacks a valid signature
    flake = builtins.toFile "flake.nix" ''
    {
      inputs = {
        deploy-rs.url = "${../..}";
        nixpkgs.url = "${inputs.nixpkgs}";
        utils.url = "${inputs.utils}";
        flake-compat.url = "${inputs.flake-compat}";
        flake-compat.flake = false;

        deploy-rs.inputs.utils.follows = "utils";
        deploy-rs.inputs.flake-compat.follows = "flake-compat";
      };

      outputs = { self, deploy-rs, nixpkgs, ... }@inputs: {
        nixosConfigurations.server = inputs.nixpkgs.lib.nixosSystem {
          system = "${system}";
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          modules = [
            ({config, pkgs, ...}: {
              services.openssh.enable = true;
              users.users.root.password = "nixos";
              boot.loader.grub.devices = [ "/dev/disk/by-label/boot" ];
              fileSystems = {
                "/" = {
                  device = "/dev/vda";
                  fsType = "ext4";
                };

                "/boot" = {
                  device = "/dev/disk/by-label/boot";
                  fsType = "vfat";
                };
              };
            })
          ];
        };
        deploy.nodes = {
          server = {
            hostname = "server";
            sshUser = "root";
            profiles.system.path = inputs.deploy-rs.lib."${system}".activate.nixos self.nixosConfigurations.server;
            sshOpts = [
              "-o" "UserKnownHostsFile=/dev/null"
              "-o" "StrictHostKeyChecking=no"
            ];
          };
        };

        checks = builtins.mapAttrs (_: deployLib: deployLib.deployChecks self.deploy) inputs.deploy-rs.lib;
      };
    }'';
  in pkgs.nixosTest ({
    inherit nodes;
    name = "simple-deploy-test";
    skipLint = true;

    testScript = ''
      start_all()

      client.succeed("mkdir tmp && cd tmp")
      client.succeed("cp ${flake} ./flake.nix")

      # generate keypair and install public key on server
      client.succeed("mkdir -m 700 /root/.ssh")
      client.succeed('${pkgs.openssh}/bin/ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519 -N ""')
      public_key = client.succeed("${pkgs.openssh}/bin/ssh-keygen -y -f /root/.ssh/id_ed25519")
      public_key = public_key.strip()
      client.succeed("chmod 600 /root/.ssh/id_ed25519")
      server.succeed("mkdir -m 700 /root/.ssh")
      server.succeed("echo '{}' > /root/.ssh/authorized_keys".format(public_key))

      # test ssh + add to list of known hosts
      server.wait_for_unit("sshd")
      server.wait_for_open_port(22)
      client.wait_for_unit("network.target")
      client.succeed(
        "ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no server 'echo hello world' >&2",
        timeout=30
      )

      # finally deploy to the server
      client.succeed("${pkgs.deploy-rs.deploy-rs}/bin/deploy -s --remote-build .#server -- --offline")

      server.succeed("ls -lasi")
    '';
  });
}
