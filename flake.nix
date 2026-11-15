{
  description = "orgnomics - Neovim Orgmode Enhancements";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";

    ldx = {
      url = "github:ar-at-localhost/ldx";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    yalms = {
      url = "github:ar-at-localhost/yalms";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {self, ...} @ inputs: let
    inherit (inputs.nixpkgs) lib;

    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
    ];

    forEachSupportedSystem = f:
      lib.genAttrs supportedSystems (
        system:
          f {
            inherit self system;
            pkgs = import inputs.nixpkgs {
              inherit system;
              overlays = [
                inputs.ldx.overlays.default
                inputs.yalms.overlays.default
              ];
            };
          }
      );

    mkOutputs = pkgs: {
      inherit (pkgs.vimPlugins) yalms;
      default = pkgs.callPackage ./vim-plugin.nix {};
    };
  in {
    devShells = forEachSupportedSystem (
      {pkgs, ...}: {
        default = pkgs.mkShell {
          packages = with pkgs; [alejandra ldx];
          shellHook = ''
            ldx sync
            eval $(ldx env)
          '';
        };
      }
    );

    packages = forEachSupportedSystem (
      {pkgs, ...}: mkOutputs pkgs
    );

    overlays.default = final: prev: (let
      outputs = mkOutputs prev;
    in {
      vimPlugins =
        prev.vimPlugins
        // {
          orgnomics = outputs.default;
        };
    });

    checks = forEachSupportedSystem (
      {pkgs, ...}: mkOutputs pkgs
    );

    nixvimModules.orgnomics = ./nixvim.nix;
  };
}
