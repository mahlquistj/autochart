{
  description = "Autochart - local AI chart generation for Clone Hero and YARG";

  inputs = {
    # Pinned by flake.lock. This revision carries node 24, electron 43 and ffmpeg
    # 9.0.1, which is what the release pins in scripts/runtime-artifacts.json.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # x86_64-linux only for now: Electron and onnxruntime-node have no official
      # Linux ARM binaries here, and the app's own target matrix stops at linux-x64.
      systems = [ "x86_64-linux" ];
      forSystems = f: lib.genAttrs systems f;
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };
    in
    {
      # Install from a NixOS or home-manager config with
      #   nixpkgs.overlays = [ autochart.overlays.default ];
      #   home.packages = [ pkgs.autochart ];
      overlays.default = import ./nix/overlay.nix;
      overlays.autochart = self.overlays.default;

      # `nix fmt` formats the Nix files in the repo.
      formatter = forSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      devShells = forSystems (system: {
        default = (pkgsFor system).callPackage ./nix/dev-shell.nix { };
      });

      packages = forSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          autochart = pkgs.autochart;
          # The app payload without the Electron runtime: npm dependencies, vite
          # bundle, engine pack. Build this to refresh nix/npm-deps-hash.txt.
          autochart-app = pkgs.autochart-app;
          default = pkgs.autochart;
        }
      );

      apps = forSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          autochart = {
            type = "app";
            program = lib.getExe pkgs.autochart;
            meta = {
              inherit (pkgs.autochart.meta) description;
              mainProgram = "autochart";
            };
          };
          default = self.apps.${system}.autochart;
        }
      );
    };
}
