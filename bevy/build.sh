#!/usr/bin/env bash
# Builds the in-process Bevy dashboard widget: the harness + every app under
# apps/ (Rust cdylibs: Bevy + wgpu on Qt's Vulkan device) and the Qt QML
# plugin, installed as the QML module `Bevy` under ~/.config/quickshell/modules
# (gitignored) with the apps in modules/Bevy/apps/<name>/.
# Needs: rust/cargo, cmake, ninja, a C++ compiler, Qt 6 development files
# (qt6-base, qt6-declarative), vulkan-headers, libvulkan at runtime.
set -euo pipefail
cd "$(dirname "$0")"
cargo build --release
cmake -S qml -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build
out="${XDG_CONFIG_HOME:-$HOME/.config}/quickshell/modules/Bevy"
mkdir -p "$out/apps"
rm -f "$out"/libbevy_widget.so
cp build/Bevy/qmldir build/Bevy/libbevyqml.so "$out"/
cp build/Bevy/*.qmltypes "$out"/ 2>/dev/null || true
for dir in apps/*/; do
  name=$(basename "$dir")
  [ -f "$dir/Cargo.toml" ] || continue
  mkdir -p "$out/apps/$name"
  cp "target/release/lib$name.so" "$out/apps/$name/"
  if [ -d "$dir/assets" ]; then rm -rf "$out/apps/$name/assets"; cp -r "$dir/assets" "$out/apps/$name/"; fi
  echo "installed app $name"
done
echo "installed QML module Bevy to $out"
echo "quickshell needs QSG_RHI_BACKEND=vulkan and QML2_IMPORT_PATH=${out%/Bevy} (see hypr/hyprland.lua)"
