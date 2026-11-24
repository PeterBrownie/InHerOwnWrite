#!/bin/zsh
# Double-click this file in Finder to build In Her Own Write, install it in your
# Applications folder, and open it. Run it again after updating the code.
cd "${0:A:h}" || exit 1

name="In Her Own Write"
staged=".build/$name.app"
installed="$HOME/Applications/$name.app"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed once."
  echo "Click Install in the window that appears, then double-click this file again."
  xcode-select --install
  exit 1
fi

echo "Preparing $name..."
swift build -c release --product InHerOwnWrite --quiet 2>/dev/null \
  || swift build -c release --product InHerOwnWrite \
  || exit 1
binary="$(swift build -c release --product InHerOwnWrite --show-bin-path)/InHerOwnWrite"

rm -rf "$staged"
mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
cp "$binary" "$staged/Contents/MacOS/InHerOwnWrite"
cp Resources/AppIcon.icns "$staged/Contents/Resources/AppIcon.icns"
cat > "$staged/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>In Her Own Write</string>
  <key>CFBundleDisplayName</key><string>In Her Own Write</string>
  <key>CFBundleIdentifier</key><string>local.inherownwrite.journal</string>
  <key>CFBundleExecutable</key><string>InHerOwnWrite</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSQuitAlwaysKeepsWindows</key><false/>
</dict>
</plist>
PLIST
# Lets the app update itself: the commit it was built from, where this copy of the code lives (so this Mac
# can build updates), and the GitHub repository (so a copy sent to another Mac can download them).
# --release is for GitHub's build, whose copy of the code is thrown away afterward.
if commit="$(git rev-parse HEAD 2>/dev/null)"; then
  plutil -insert InHerOwnWriteCommit -string "$commit" "$staged/Contents/Info.plist"
  [[ "$1" == "--release" ]] || plutil -insert InHerOwnWriteSource -string "$PWD" "$staged/Contents/Info.plist"
fi
repository="${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null)}"
repository="${${repository%.git}##*github.com[:/]}"
if [[ "$repository" =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' ]]; then
  plutil -insert InHerOwnWriteRepository -string "$repository" "$staged/Contents/Info.plist"
fi
codesign --force --sign - "$staged" >/dev/null 2>&1

# The app's updater builds here while it keeps running, then swaps the new copy in itself.
if [[ "$1" == "--stage-only" || "$1" == "--release" ]]; then
  echo "Built $staged"
  exit 0
fi

# Installing in ~/Applications keeps the Dock icon pointing at a stable place.
if [[ -d "$installed" ]] && diff -rq "$staged" "$installed" >/dev/null 2>&1; then
  echo "$name is up to date."
elif pgrep -xq InHerOwnWrite; then
  echo "A new version is ready. Quit $name, then double-click this file again to install it."
else
  mkdir -p "$HOME/Applications"
  rm -rf "$installed"
  ditto "$staged" "$installed"
  # Refresh the icon Finder and the Dock show.
  touch "$installed"
  echo "Installed $name in your Applications folder."
fi

[[ "$1" == "--no-open" ]] || open "$installed"
