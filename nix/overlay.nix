final: prev: {
  # The wrapped app: Electron runtime from the store plus the payload assembled by
  # nix/package.nix. Override with `autochart.override { checkForUpdates = true; }`.
  autochart = final.callPackage ./package.nix { };

  # Just the app payload (npm dependencies, vite bundle, engine pack), without the
  # Electron runtime. Build this to refresh nix/npm-deps-hash.txt.
  autochart-app = final.autochart.passthru.app;
}
