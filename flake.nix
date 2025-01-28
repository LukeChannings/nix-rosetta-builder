{
  description = "Lima-based, Rosetta 2-enabled, Apple silicon (macOS/Darwin)-hosted Linux builder";

  inputs = {
    nixpkgs.url = "nixpkgs";

    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # See https://lix.systems/add-to-config/#flake-based-configurations for the latest version
    lix-module.url = "https://git.lix.systems/lix-project/nixos-module/archive/2.92.0.tar.gz";
    lix-module.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixos-generators, nixpkgs, lix-module }:
  let
    darwinSystem = "aarch64-darwin";
    linuxSystem = builtins.replaceStrings [ "darwin" ] [ "linux" ] darwinSystem;

  in {
    packages."${linuxSystem}" =
    let
      arguments = { inherit linuxSystem nixos-generators nixpkgs lix-module; };
      pkgs = import nixpkgs { system = linuxSystem; overlays = [ lix-module.overlays.default ]; };
    in {
      default = pkgs.callPackage ./package.nix (arguments // { onDemand = false; });
      on-demand = pkgs.callPackage ./package.nix (arguments // { onDemand = true; });
    };

    devShells."${darwinSystem}".default =
    let
      pkgs = nixpkgs.legacyPackages."${darwinSystem}";
    in pkgs.mkShell {
      packages = [ pkgs.lima ];
    };

    darwinModules.default = import ./module.nix {
      images = self.packages."${linuxSystem}";
      inherit linuxSystem;
    };
  };
}
