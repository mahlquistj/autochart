# Nix

The repo carries a flake with a dev shell, an installable app package, and an overlay.
Only `x86_64-linux` is defined. Files: `flake.nix`, `nix/package.nix`,
`nix/dev-shell.nix`, `nix/overlay.nix`, `nix/npm-deps-hash.txt`.

## Development shell

    nix develop
    npm ci
    npm run dev          # browser preview on http://127.0.0.1:5173
    npm run electron:dev # the real app

The shell provides `nodejs_24`, `ffmpeg`, `git`, `python3`, `gcc`, `gnumake`,
`pkg-config`, `which`, `nixfmt` and `xvfb-run`. Two variables matter for Electron:

- `ELECTRON_SKIP_BINARY_DOWNLOAD=1` keeps npm from pulling its own Electron build.
- `ELECTRON_OVERRIDE_DIST_PATH=${electron_43-bin}/libexec/electron` makes
  `require("electron")`, `npx electron` and the `electron:*` harnesses run the nixpkgs
  runtime instead. `node_modules/electron/path.txt` is never written, and
  `electron/index.js` falls back to the `electron` name on PATH in that case.

Generation, native export and file dialogs need Electron, so use `electron:dev` for
anything that touches the engine or the filesystem.

## Building the app

    nix build .#autochart
    ./result/bin/autochart
    nix run .#autochart

`nix/package.nix` runs in two stages:

1. **App payload** (`autochart-app`, also `packages.autochart-app`): `buildNpmPackage`
   installs dependencies from the lockfile with `ELECTRON_SKIP_BINARY_DOWNLOAD=1` and
   `ONNXRUNTIME_NODE_INSTALL=skip` - Electron's own build and ONNX Runtime's CUDA
   execution providers are the two things npm would download into the tree - then runs
   `vite build` and copies the `package.json` `build.files` allowlist into
   `share/autochart/app`. Source maps are dropped, as in the release archives.
   `autoPatchelfHook` gives the prebuilt ONNX Runtime ELFs a store interpreter and
   rpath. The install check loads `onnxruntime-node`, `tar` and `yauzl` from the staged
   directory and reads `engine/manifest.json`, which is what catches an allowlist that
   drifted from `build.files`.
2. **Launcher**: `bin/autochart`, a wrapper around the nixpkgs Electron runtime built by
   `makeBinaryWrapper`. It passes the app directory as the first argument and sets the
   environment the app reads: `AUTOCHART_FFMPEG_PATH` and `AUTOCHART_NODE_BIN` to the
   nixpkgs binaries, both on `PATH`, and `AUTOCHART_UPDATE_CHECK=0`. It also sets
   `ELECTRON_FORCE_IS_PACKAGED=1`, because Electron decides `app.isPackaged` from the
   executable's name: a packaged app is one whose binary is *not* called `electron`.
   Without it `electron/main.cjs` stays in dev mode and loads the Vite server URL
   instead of `dist/index.html`. Nothing of the ~225 MB Electron binary is copied into
   this output. The `.desktop` entry and icons are installed here too.

Runtime versions are pinned through the flake's nixpkgs input. The wrapper takes the
Electron build, FFmpeg and Node as arguments:

    pkgs.autochart.override {
      electronRuntime = pkgs.electron_43-bin;  # must match package.json's electron major
      ffmpegPackage = pkgs.ffmpeg_6;
      nodeRuntime = pkgs.nodejs_24;
      checkForUpdates = true;   # let the app poll the release feed
      sandbox = true;           # export CHROME_DEVEL_SANDBOX to the runtime's helper
    }

`electronRuntime` must be a major the app was built against: the engine's WebGPU child
loads `onnxruntime-node`'s prebuilt binding through this runtime, and the N-API version
in `bin/napi-v6` is what Electron 43 exposes. The nixpkgs Electron `chrome-sandbox` is
not setuid, so the renderer sandbox relies on unprivileged user namespaces, which NixOS
enables; `sandbox = true` only helps if a setuid helper is configured separately.

## Installing

Through the overlay, in NixOS or Home Manager:

    {
      inputs.autochart.url = "github:mahlquistj/autochart";
      nixpkgs.overlays = [ autochart.overlays.default ];
      home.packages = [ pkgs.autochart ];   # or environment.systemPackages
    }

`programs.<...>`-style module wiring, auto-update and system-wide model packs are out of
scope here; `docs/install.md` covers the AppImage and DEB/RPM releases.

## Dependency hash

`nix/npm-deps-hash.txt` holds `buildNpmPackage`'s fixed-output hash for `npm ci`. After
a `package.json` or `package-lock.json` change, build the payload alone and copy the
`got:` value it prints into that file:

    nix build .#autochart-app   # fails once, reporting the correct hash

`nix flake check` evaluates every output and runs the payload's install check, which
loads `onnxruntime-node`, `tar` and `yauzl` from the staged app directory and reads
`engine/manifest.json`. That check is what catches an allowlist that drifted from
`build.files`.

## Not covered

- `armv7l-linux`, `aarch64-linux` and `aarch64-darwin`: ONNX Runtime and Electron
  prebuilts here are x64 only, as in the app's own target list.
- CUDA and other GPU execution providers, which `onnxruntime-node`'s install script
  downloads separately. CPU inference and the WebGPU path are what this builds.
- ONNX model files. They stay outside the package and download on first launch (about
  952 MB), as they do for the release builds; `AUTOCHART_MODELS_ROOT` and
  `settings.modelsFolder` are how to point at a prepared store instead.
- The installer, release-archiving and update-feed flow. Nothing in `npm run dist:*`,
  `release:stage` or the FFmpeg Corresponding Source build is used or affected by the
  Nix path.
- A GUI smoke test for the wrapped app: the flake checks never start Electron. `nix run
  .#autochart` is the manual test.
