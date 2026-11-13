{
  lib,
  mkShell,
  electron_43-bin,
  ffmpeg,
  gcc,
  git,
  gnumake,
  nodejs_24,
  nixfmt,
  pkg-config,
  python3,
  stdenv,
  which,
  xvfb,
  xvfb-run,
  electronRuntime ? electron_43-bin,
}:

mkShell {
  name = "autochart-dev";

  packages = [
    # Toolchain. Node matches the runtime the release bundles (see
    # scripts/runtime-artifacts.json), FFmpeg matches the pinned 9.0.1.
    nodejs_24
    ffmpeg
    git
    python3 # node-gyp, scripts/prepare-huggingface.py
    gcc # npm optional-dependency builds
    gnumake
    pkg-config
    which
    electronRuntime
    nixfmt # nix/ in this repo

    # The electron:* harnesses (npm run test:generation-queue, test:video-preview,
    # ...) start a real Electron, so they need a display when run headless.
    xvfb
    xvfb-run
  ];

  # npm must not download an Electron dist: that copy has no store interpreter and
  # cannot start here. electron/index.js resolves through ELECTRON_OVERRIDE_DIST_PATH
  # instead, so `npx electron`, `npm run electron:dev` and the electron:* scripts run
  # on the nixpkgs runtime, sandbox helper included.
  ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
  ELECTRON_OVERRIDE_DIST_PATH = "${electronRuntime}/libexec/electron";

  shellHook = ''
    # onnxruntime-node's prebuilt binaries in ./node_modules link against a distro
    # libstdc++; the store one is not on the default search path.
    export LD_LIBRARY_PATH="${lib.getLib stdenv.cc.cc}/lib''${LD_LIBRARY_PATH:+:}$LD_LIBRARY_PATH"

    echo "autochart dev shell - node $(node --version), npm $(npm --version), electron ${lib.getVersion electronRuntime}, ffmpeg ${lib.getVersion ffmpeg}"
    echo "once per checkout:  npm ci"
    echo "then:               npm run dev | npm run electron:dev | npm run test:i18n"
    echo "the ~952 MB model pack downloads on first launch (or via npm run smoke:generate)."
  '';
}
