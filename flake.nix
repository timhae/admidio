{
  description = "Admidio - a free open source user management system for organizations (package, NixOS module and tests)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      overlays.default = final: prev: {
        # php83 matches the PHP version of the official Docker image
        admidio = final.callPackage ./nix/package.nix { php = final.php83; };
      };

      nixosModules = rec {
        admidio =
          { pkgs, lib, ... }:
          {
            imports = [ ./nixos/module.nix ];
            services.admidio.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.admidio;
          };
        default = admidio;
      };

      packages = forAllSystems (system: rec {
        inherit (mkPkgs system) admidio;
        default = admidio;
      });

      formatter = forAllSystems (system: (mkPkgs system).nixfmt);

      checks = forAllSystems (system: rec {
        admidio = (mkPkgs system).testers.runNixOSTest ./nixos/test.nix;
        default = admidio;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.php83
              pkgs.php83.packages.composer
              pkgs.nixfmt
            ];
          };
        }
      );
    };
}
