{
  description = "Jutlandia site using uv2nix";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = pkgs.python3;
        in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
            ]
          )
      );
      
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          pythonSet = pythonSets.${system}.overrideScope editableOverlay;
          virtualenv = pythonSet.mkVirtualEnv "jutlandia-site-dev-env" workspace.deps.all;
        in
        {
          default = pkgs.mkShell {
            packages = [
              virtualenv
              pkgs.uv
            ];
            env = {
              UV_NO_SYNC = "1";
              UV_PYTHON = pythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
              . ${virtualenv}/bin/activate
            '';
          };
        }
      );

      packages = forAllSystems (system: {
        default = pythonSets.${system}.mkVirtualEnv "jutlandia-site-env" workspace.deps.default;
      });

    
    nixosModules.website = { config, pkgs, lib, ... }@args:
      with lib;
      let
        cfg = config.services.website;
        # Reference the package built for the system the module is running on
        jutlandia-site = self.packages.${pkgs.system}.default;
      in
      {
        options.services.website = {
          enable = mkEnableOption "Website service";

          domain = mkOption {
            type = types.str;
          };

          databaseUrl = mkOption {
            type = types.str;
            default = "sqlite:///var/lib/website/jutlandia.db";
          };

          appSecretKeyFile = mkOption {
            type = types.path;
          };

          discord = mkOption {
            type = with types; submodule {
              options = {
                clientId = mkOption {
                  type = types.str;
                };
                guildId = mkOption {
                  type = types.str;
                };
                adminRoleId = mkOption {
                  type = types.str;
                };
                redirectUri = mkOption {
                  type = types.str;
                };

                clientSecretFile = mkOption {
                  type = types.path;
                };
                infraClientSecretFile = mkOption {
                  type = types.path;
                };
              };
            };
          };
        };

        config = mkIf cfg.enable {
          systemd.services.website = {
            description = "Jutlandia Website service";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];
            environment = {
              DISCORD_GUILD_ID = cfg.discord.guildId;
              DISCORD_CLIENT_ID = cfg.discord.clientId;
              DISCORD_ADMIN_ROLE_ID = cfg.discord.adminRoleId;
              DISCORD_REDIRECT_URI = cfg.discord.redirectUri;

              SQL_DB_URI = cfg.databaseUrl;
            };
            script = ''
              export DISCORD_INFRA_CLIENT_SECRET="$(cat $CREDENTIALS_DIRECTORY/discord-infra-client-secret)"
              export DISCORD_CLIENT_SECRET="$(cat $CREDENTIALS_DIRECTORY/discord-client-secret)"
              export APP_SECRET_KEY="$(cat $CREDENTIALS_DIRECTORY/app-secret-key)"

              ${jutlandia-site}/bin/run_site
            '';
            serviceConfig = let
              run_site = pkgs.writeShellScript "load-secrets-and-run.sh" ''
              DISCORD_INFRA_CLIENT_SECRET="$(cat $CREDENTIALS_DIRECTORY/discord-infra-client-secret)"
              DISCORD_CLIENT_SECRET="$(cat $CREDENTIALS_DIRECTORY/discord-client-secret)"
              APP_SECRET_KEY="$(cat $CREDENTIALS_DIRECTORY/app-secret-key)"

              ${jutlandia-site}/bin/run_site
              '';
              in {
              PermissionsStartOnly = true;
              LimitNPROC = 512;
              LimitNOFILE = 1048576;
              NoNewPrivileges = true;
              User = "jut-website";
              # ExecStart = "${run_site}";
              Restart = "on-failure";
              LoadCredential = [
                "discord-infra-client-secret:${cfg.discord.infraClientSecretFile}"
                "discord-client-secret:${cfg.discord.clientSecretFile}"
                "app-secret-key:${cfg.appSecretKeyFile}"
              ];
            };
          };

          services.nginx.enable = true;
          services.nginx.virtualHosts."${cfg.domain}" = {
            locations."/" = {
              proxyPass = "http://127.0.0.1:5000";
            };
          };
            
          systemd.tmpfiles.settings."10-website" = {
            "/var/lib/website" = {
              d = {
                user = "jut-website";
                mode = "0755";
                group = "jut-website";
              };
            };
          };

          users.users.jut-website = {
            isSystemUser = true;
            description = "User for the website service";
            group = "jut-website";
          };
          users.groups.jut-website = {};
        };
      };
  };
}
