{ inputs =
    { easy-ps.url = "github:ursi/easy-purescript-nix/flake";
      nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

      spago2nix-repo =
        { url = "github:justinwoo/spago2nix";
          flake = false;
        };

      utils.url = "github:ursi/flake-utils/2";
    };

  outputs = { spago2nix-repo, utils, ... }@inputs:
    with builtins;
    utils.default-systems
      ({ easy-ps, make-shell, pkgs, ... }:
         let
           p = pkgs;
           spago2nix = import spago2nix-repo { inherit pkgs; inherit (pkgs) nodejs; };
         in
         { defaultPackage =
             let
               sp = import ./spago-packages.nix { inherit pkgs; };
               outputs = sp.mkBuildProjectOutput { src = ./src; purs = easy-ps.purs-0_13_8; };

               server =
                 p.runCommand "purescript-language-server" {}
                   ''
                   ${easy-ps.purs-0_13_8}/bin/purs bundle \
                     -o $out \
                     --module LanguageServer.IdePurescript.Main \
                     --main LanguageServer.IdePurescript.Main \
                     "${outputs}/**/*.js"
                   '';
             in
             with pkgs;
               p.runCommand "purescript-language-server" {}
               ''
               mkdir $out
               cp -r ${nodePackages.purescript-language-server}/. ./.
               chmod -R +w lib
               cp ${server} lib/node_modules/purescript-language-server/server.js
               cp -rt $out bin lib
               '';

           devShell =
             make-shell
               { packages =
                   [ easy-ps.purs-0_13_8
                     easy-ps.spago
                     pkgs.nodejs
                     spago2nix
                   ];
               };
         }
      )
      inputs;
}
