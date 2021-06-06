with builtins;
system:
  let
    p = pkgs;
    inherit (import ./inputs.nix system) easy-ps pkgs;
  in
  { build =
      let
        sp = import ./spago-packages.nix { inherit pkgs; };
        outputs = sp.mkBuildProjectOutput { src = ../src; purs = easy-ps.purs-0_13_8; };

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

    shell =
      p.mkShell
        { buildInputs =
            [ easy-ps.purs-0_13_8
              easy-ps.spago
              easy-ps.spago2nix
              pkgs.nodejs
            ];
        };
  }
