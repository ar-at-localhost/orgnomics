{
  pkgs,
  lib,
  ...
}: let
  inherit (import ./version.nix) version;
  root = ./.;

  src = lib.fileset.toSource {
    inherit root;
    fileset = lib.fileset.unions [
      (root + "/lua")
    ];
  };
in
  pkgs.vimUtils.buildVimPlugin {
    pname = "orgnomics";
    inherit version src;
    dependencies = [
      pkgs.vimPlugins.orgmode
      pkgs.vimPlugins.snacks-nvim
      pkgs.vimPlugins.yalms
    ];
    doCheck = false;
  }
