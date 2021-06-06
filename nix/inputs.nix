with builtins;
system:
  rec
  { easy-ps =
      import
        (fetchGit
           { url = "https://github.com/justinwoo/easy-purescript-nix.git";
             rev = "47bdc016c7d56e987ca1aca690b1d6c9816a8584";
           }
        )
        { inherit pkgs; };

    pkgs =
      import
        (fetchTarball
           { url = "https://github.com/NixOS/nixpkgs/archive/efee454783c5c14ae78687439077c1d3f0544d97.tar.gz";
             sha256 = "1qk4g8rav2mkbd6y2zr1pi3pxs4rwlkpr8xk51m0p26khprxvjaf";
           }
        )
        { inherit system; };
  }
