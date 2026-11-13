{
  lib,
  buildNpmPackage,
  stdenv,
  stdenvNoCC,
  autoPatchelfHook,
  electron_43-bin,
  ffmpeg,
  makeBinaryWrapper,
  makeDesktopItem,
  nodejs_24,
  electronRuntime ? electron_43-bin, # the launcher wraps this Electron
  ffmpegPackage ? ffmpeg,
  nodeRuntime ? nodejs_24,
  # The shipped builds poll the update feed and offer an AppImage self-swap, which a
  # Nix-managed install cannot do. Off by default: the package manager updates it.
  checkForUpdates ? false,
  # Chrome's SUID sandbox helper, exported to the app by the launcher. The prebuilt
  # Electron ships it world-readable, and nixpkgs enables unprivileged user namespaces
  # by default, so the sandbox works without it and this stays opt-in.
  sandbox ? false,
}:

let
  inherit (lib)
    cleanSourceWith
    escapeShellArg
    licenses
    sourceTypes
    ;

  manifest = lib.importJSON ../package.json;
  buildConfig = manifest.build;

  pname = "autochart";
  version = manifest.version;
  appId = buildConfig.appId;
  productName = buildConfig.productName;
  payload = "share/${pname}/app";

  # The flake source already drops gitignored paths; this also drops the
  # development-only trees so the payload copy cannot pick them up. Not a `src`
  # function argument: callPackage would fill that with the `src` VCS package.
  appSrc = cleanSourceWith {
    src = ../.;
    filter =
      name: _type:
      let
        relative = lib.removePrefix "${toString ../.}/" (toString name);
        firstSegment = builtins.head (lib.splitString "/" relative);
        # ONNX graphs are downloaded during setup; a dev checkout keeps them as
        # symlinks that would be copied broken.
        modelBlob =
          lib.hasPrefix "engine/models-onnx/" relative && !lib.hasSuffix "/manifest.json" relative;
        pruned = lib.elem firstSegment [
          ".github"
          ".wrangler"
          "Projects"
          "cloudflare"
          "dist"
          "dist-web"
          "fixtures"
          "node_modules"
          "production"
          "release"
        ];
      in
      !pruned && !modelBlob;
  };

  # node names native module directories after process.arch.
  nodeArch =
    {
      aarch64 = "arm64";
      arm = "arm";
      i686 = "ia32";
      x86_64 = "x64";
    }
    .${stdenvNoCC.hostPlatform.parsed.cpu.name}
      or (throw "autochart: unsupported cpu '${stdenvNoCC.hostPlatform.parsed.cpu.name}'");

  # Runtime payload, mirroring package.json "build.files" so a Nix install runs the
  # same file set as the AppImage: renderer bundle, main-process code, engine pack,
  # shared modules, third-party notices, and only the node_modules the app loads.
  # Every pattern has to match at build time, so an upstream rename breaks the
  # build here instead of the first launch. Keep in sync with "build.files".
  appFiles = [
    "LICENSE"
    "package.json"

    "config/supported-targets.json"
    "config/human-labels.json"
    "config/human-labels.cjs"
    "config/supported-targets.cjs"

    "electron/**"

    "engine/manifest.json"
    "engine/catalog.json"
    "engine/bin/**"
    "engine/lib/**"
    "engine/licenses/**"

    "shared/chartWriter.js"
    "shared/generatedVersion.js"
    "shared/chartProvenance.js"
    "shared/finalSlots.js"
    "shared/projectFile.js"
    "shared/chartDelay.js"
    "shared/timingSignature.js"

    "docs/third-party-notices.md"
    "docs/privacy.md"
    "docs/release-notes.md"
    "docs/install.md"
    "docs/blueoak-1.0.0.txt"
    "docs/fs-minipass-isc.txt"
    "docs/minizlib-mit.txt"
    "docs/onnxruntime-third-party-notices.txt"
    "docs/lgpl-2.1.txt"
    "docs/xiph-bsd.txt"
    "docs/libvpx-bsd.txt"
    "docs/dav1d-bsd.txt"

    # Written by `npm run build` (vite) into ./dist.
    "dist/**"

    "node_modules/onnxruntime-node/package.json"
    "node_modules/onnxruntime-node/dist/*.js"
    "node_modules/onnxruntime-node/bin/napi-v6/linux/${nodeArch}/**"
    "node_modules/onnxruntime-common/package.json"
    "node_modules/onnxruntime-common/dist/cjs/*.js"
    "node_modules/onnxruntime-common/dist/cjs/package.json"
    "node_modules/tar/package.json"
    "node_modules/tar/dist/commonjs/index.min.js"
    "node_modules/tar/dist/commonjs/package.json"
    "node_modules/yauzl/package.json"
    "node_modules/yauzl/*.js"
    "node_modules/pend/package.json"
    "node_modules/pend/index.js"
  ];

  commonMeta = with lib; {
    description = manifest.description;
    homepage = "https://github.com/mahlquistj/autochart";
    changelog = "https://github.com/mahlquistj/autochart/releases";
    license = licenses.agpl3Plus;
    # Electron and onnxruntime-node both ship prebuilt x64 Linux binaries here, and
    # the app's own target matrix does the same.
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with sourceTypes; [
      fromSource
      binaryNativeCode
    ];
  };

  # ---- stage 1: npm dependencies (fixed output), vite bundle, app payload ----
  app = buildNpmPackage {
    pname = "${pname}-app";
    inherit version;
    src = appSrc;

    # `npm ci` output hash. After a package-lock change, `nix build .#autochart-app`
    # fails and prints the value to paste here.
    npmDepsHash = lib.removeSuffix "\n" (builtins.readFile ./npm-deps-hash.txt);

    # onnxruntime-node ships prebuilt ELFs that need an interpreter and rpath.
    nativeBuildInputs = [ autoPatchelfHook ];
    buildInputs = [ (lib.getLib stdenv.cc.cc) ]; # libstdc++ for libonnxruntime.so

    # The Electron copy npm would download cannot start outside the store; stage 2
    # runs the app on `electronRuntime` above. electron/index.js falls back to the
    # `electron` name under ELECTRON_OVERRIDE_DIST_PATH when path.txt is missing.
    env.ELECTRON_SKIP_BINARY_DOWNLOAD = "1";

    # onnxruntime-node's install script fetches the CUDA execution providers from
    # api.nuget.org on linux/x64. The CPU and WebGPU bindings this app uses ship
    # inside the npm package, so skip the download instead of adding a NuGet pin.
    env.ONNXRUNTIME_NODE_INSTALL = "skip";

    installPhase = ''
      runHook preInstall

      app=$out/${payload}
      mkdir -p "$app"
      shopt -s nullglob globstar
      for pattern in ${lib.concatStringsSep " " (map escapeShellArg appFiles)}; do
        matches=( $pattern )
        if [ ''${#matches[@]} -eq 0 ]; then
          echo "autochart: nothing matched '$pattern' - nix/package.nix drifted from package.json build.files" >&2
          exit 1
        fi
        for file in "''${matches[@]}"; do
          mkdir -p "$app/$(dirname "$file")"
          cp -fR --preserve=mode "$file" "$app/$file"
        done
      done

      # The release package ships no source maps.
      if [ -d "$app/dist" ]; then find "$app/dist" -name '*.map' -delete; fi

      runHook postInstall
    '';

    # The payload carries only an allowlisted slice of node_modules, and ORT's
    # native library has to survive the store patch: loading it here catches a
    # missing runtime dependency and an unpatched binary at build time. The engine
    # runs on this same standalone node, so check it can start too.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      ${nodeRuntime}/bin/node -e '
        const path = require("node:path");
        const app = process.argv[1];
        const ort = require(path.join(app, "node_modules/onnxruntime-node"));
        if (typeof ort.InferenceSession !== "function") throw new Error("onnxruntime-node has no InferenceSession");
        require(path.join(app, "node_modules/tar"));
        require(path.join(app, "node_modules/yauzl"));
        require(path.join(app, "engine/manifest.json"));
      ' "$out/${payload}"
      runHook postInstallCheck
    '';

    meta = commonMeta // {
      # Not runnable on its own: it is stage 2's app directory.
      hydraPlatforms = [ ];
    };
  };

  desktopItem = makeDesktopItem {
    name = pname;
    desktopName = productName;
    genericName = "Chart editor";
    comment = manifest.description;
    exec = "${pname} %U";
    icon = pname;
    terminal = false;
    startupNotify = true;
    startupWMClass = productName;
    categories = lib.filter (x: x != "") (lib.splitString ";" buildConfig.linux.category);
    keywords = [
      "guitar"
      "chart"
      "clone-hero"
      "yarg"
      "tabs"
    ];
  };

  ffmpegExe = "${ffmpegPackage}/bin/ffmpeg";
  nodeExe = "${nodeRuntime}/bin/node";

  # Launcher arguments, one per line so the shell passes them as separate words.
  # The engine's WebGPU child needs a standalone node and media conversion needs
  # ffmpeg, both as absolute paths because a .desktop launch inherits a sanitized
  # PATH. The shipped builds poll the update feed and offer an AppImage self-swap,
  # which a Nix-managed install can neither do nor mean.
  wrapperArgs = lib.concatStringsSep " \\\n    " (
    [
      "--set ELECTRON_FORCE_IS_PACKAGED 1"
      "--set AUTOCHART_FFMPEG_PATH ${escapeShellArg ffmpegExe}"
      "--set AUTOCHART_NODE_BIN ${escapeShellArg nodeExe}"
      "--prefix PATH : ${escapeShellArg "${lib.dirOf ffmpegExe}:${lib.dirOf nodeExe}"}"
    ]
    ++ lib.optionals (!checkForUpdates) [ "--set AUTOCHART_UPDATE_CHECK 0" ]
    ++ lib.optionals sandbox [
      "--set CHROME_DEVEL_SANDBOX ${escapeShellArg "${electronRuntime}/libexec/electron/chrome-sandbox"}"
    ]
  );

  # ---- stage 2: the launcher ----
in
stdenvNoCC.mkDerivation rec {
  inherit pname version;

  nativeBuildInputs = [ makeBinaryWrapper ];

  # Nothing to unpack, build, or check: stage 1 did all of it.
  phases = [ "installPhase" ];

  appPayload = "${app}/${payload}";

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/applications"

    # Electron has two dev-versus-packaged signals: app.isPackaged means "the
    # executable is not named electron", and process.defaultApp is true when the app
    # arrived as an argument. main.cjs only loads dist/index.html while isPackaged
    # holds, and the engine handoff keys off it too. Rather than copy the 225 MB
    # runtime binary out of the Electron package and rename it, the launcher hands
    # over the app directory and sets Electron's own override for the check.
    makeWrapper "${electronRuntime}/bin/electron" "$out/bin/${pname}" \
      ${wrapperArgs} \
      --add-flags ${escapeShellArg appPayload}

    install -Dm644 ${../public/app-icon.svg} "$out/share/icons/hicolor/scalable/apps/${pname}.svg"
    install -Dm644 ${../public/app-icon.png} "$out/share/icons/hicolor/512x512/apps/${pname}.png"
    ln -s "${desktopItem}/share/applications/${pname}.desktop" \
      "$out/share/applications/${pname}.desktop"
    runHook postInstall
  '';

  passthru = {
    inherit app desktopItem;
    runtime = {
      electron = lib.getVersion electronRuntime;
      node = nodeRuntime.version;
      ffmpeg = ffmpegPackage.version;
    };
  };

  meta = commonMeta // {
    mainProgram = pname;
  };
}
