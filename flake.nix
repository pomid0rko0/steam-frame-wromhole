# The tools' environment on NixOS: what tools/setup.sh installs elsewhere, from nixpkgs (Godot, its
# export templates, ref/'s Python, software Vulkan and EGL, xvfb, Monado) and built here (Mesa's
# Turnip with its noop drm-shim, for tools/adreno_stats.sh), plus git and gh. The versions are
# setup.sh's (V, MESA_V): one place for every machine; a Godot version nixpkgs lacks fails here.
# The tools enter this shell by themselves (tools/repo.sh); by hand: direnv (.envrc) or nix develop.
# This PC runs SteamVR, its OpenXR runtime, and has GPUs: in this shell Godot finds Monado as its
# runtime (not running unless tools/test_openxr.sh starts it), Vulkan only lavapipe without any
# implicit layer (Steam's overlay), EGL only Mesa's software one: a test can't reach the headset or
# the owner's screen, and renders as in CI. The app for the headset runs from Steam, not from here.
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      # NAME=value in setup.sh
      setup = builtins.readFile ./tools/setup.sh;
      var =
        name:
        lib.head (
          lib.concatMap (
            l:
            let
              m = builtins.match "${name}=([0-9.]+)( .*)?" l;
            in
            if m == null then [ ] else [ (lib.head m) ]
          ) (lib.splitString "\n" setup)
          ++ [ (throw "no ${name}= in tools/setup.sh") ]
        );
      V = var "V";
      MESA_V = var "MESA_V";
      forSystems = f: lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (s: f nixpkgs.legacyPackages.${s});
      packages =
        pkgs:
        let
          minor = lib.versions.majorMinor V;
          godotAttr = "godot_${lib.replaceStrings [ "." ] [ "_" ] minor}";
          godot = pkgs.${godotAttr} or (throw "nixpkgs has no ${godotAttr} (Godot ${V}, setup.sh's V)");
          templates = pkgs."${godotAttr}-export-templates-bin";
        in
        assert lib.assertMsg (godot.version == "${V}-stable") "nixpkgs' ${godotAttr} is ${godot.version}, setup.sh's V ${V}";
        assert lib.assertMsg (templates.version == godot.version) "export templates ${templates.version}, Godot ${godot.version}";
        {
          inherit godot templates;
          # setup.sh's get_adreno: the same version and options
          turnip = pkgs.stdenv.mkDerivation {
            pname = "mesa-turnip-drm-shim";
            version = MESA_V;
            src = pkgs.fetchurl {
              url = "https://archive.mesa3d.org/mesa-${MESA_V}.tar.xz";
              hash = "sha256-CXhC8+SdmWhos4aI24ewBvfUVB6TzobS80HYs+e+fJM="; # MESA_V's: a new one with it
            };
            nativeBuildInputs = with pkgs; [
              meson
              ninja
              pkg-config
              flex
              bison
              glslang
              (python3.withPackages (p: [
                p.mako
                p.pyyaml
                p.pycparser
                p.packaging
              ]))
            ];
            buildInputs = with pkgs; [
              libdrm
              expat
              zlib
              zstd
              elfutils
              libx11
              libxext
              libxfixes
              libxcb
              libxshmfence
              libxxf86vm
              libxrandr
              xorgproto
            ];
            mesonBuildType = "release";
            mesonAutoFeatures = "auto"; # meson's own default, as setup.sh has it (nixpkgs': enabled)
            postPatch = "patchShebangs ."; # its generators start with #!/usr/bin/env python3
            mesonFlags = [
              "-Dgallium-drivers="
              "-Dvulkan-drivers=freedreno"
              "-Dfreedreno-kmds=msm"
              "-Dtools=drm-shim"
              "-Dplatforms=x11"
              "-Dglx=disabled"
              "-Degl=disabled"
              "-Dgbm=disabled"
              "-Dopengl=false"
              "-Dgles1=disabled"
              "-Dgles2=disabled"
              "-Dllvm=disabled"
              "-Dvalgrind=disabled"
              "-Dlibunwind=disabled"
              "-Dvideo-codecs="
            ];
          };
        };
    in
    {
      packages = forSystems packages;

      devShells = forSystems (
        pkgs:
        let
          p = packages pkgs;
          cpu = pkgs.stdenv.hostPlatform.parsed.cpu.name;
        in
        {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              p.godot
              (python3.withPackages (ps: [
                ps.numpy
                ps.scipy
                ps.pillow
                ps.moderngl
              ]))
              xvfb-run
              monado
              git
              gh
              procps
              util-linux
              unzip
            ];
            # tools/env.sh, tools/box.sh, ref/in_box.py: the tools run here, as they are
            WORMHOLE_SHELL = "nix";
            # tools/export.sh: the export templates, which Godot takes from its user data
            GODOT_TEMPLATES = "${p.templates}/share/godot/export_templates";
            # tools/env.sh's turnip
            MESA = p.turnip;
            VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.${cpu}.json";
            VK_LOADER_LAYERS_DISABLE = "~implicit~";
            XR_RUNTIME_JSON = "${pkgs.monado}/share/openxr/1/openxr_monado.json";
            __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
            LIBGL_ALWAYS_SOFTWARE = "1";
            # what the system or Steam sets that would pick other drivers, layers or a runtime than
            # these (this PC selects its Intel GPU: VK_LOADER_DRIVERS_SELECT); VK_DRIVER_FILES would
            # override VK_ICD_FILENAMES, here and in tools/env.sh's turnip
            shellHook = ''
              unset VK_DRIVER_FILES VK_ADD_DRIVER_FILES VK_LOADER_DRIVERS_SELECT VK_LOADER_DRIVERS_DISABLE \
                VK_LAYER_PATH VK_ADD_LAYER_PATH VK_INSTANCE_LAYERS VK_LOADER_LAYERS_ENABLE XR_API_LAYER_PATH DRI_PRIME
            '';
          };
        }
      );
    };
}
