{ system ? builtins.currentSystem}:
  (import ./nix system).build
