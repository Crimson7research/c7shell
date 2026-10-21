#!/usr/bin/env bash
# Static checks on the shell's QML. Run it directly: tests/test-qml-hygiene.sh
#
# Everything here is a mistake that a compositor-less test cannot catch and
# qmllint reports only as noise, but that takes the whole shell down when the
# real config loads -- quickshell aborts the entire configuration on one bad
# property assignment, so a typo in a popover nobody has opened yet is still a
# desktop with no bar on it.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"

# --------------------------------------------------------------------------
# font.pixelSize and font.weight are ints. A fractional literal is not rounded
# and is not a warning -- it is "Invalid property assignment: int expected",
# which fails the load of the file, every file that imports it, and therefore
# the shell. Common/SectionLabel.qml carries the note that 9.5 is written as
# 10 for exactly this reason; this makes the rule enforceable instead of
# folklore.
# --------------------------------------------------------------------------
hits=$(grep -rn --include='*.qml' -E '\b(pixelSize|weight):[[:space:]]*[0-9]+\.[0-9]' "$src" || true)
if [[ -n $hits ]]; then
  fail "font.pixelSize and font.weight are ints; a fractional literal fails the
  whole configuration load, not just the binding. Round it (the design's 9.5
  is written as 10 -- see Common/SectionLabel.qml):\n$hits"
fi

# --------------------------------------------------------------------------
# A singleton named from another directory without importing its module
# resolves at call time, not load time: the shell starts clean and the button
# does nothing the first time somebody presses it. Files inside Services/ are
# exempt -- the containing directory is an implicit import, so siblings
# resolve without one, which is why DisplayService has always worked.
# --------------------------------------------------------------------------
while read -r f; do
  case $f in "$src"/Services/*) continue ;; esac
  grep -q '^import qs.Services' "$f" && continue
  while read -r used; do
    [[ -f $src/Services/$used.qml ]] || continue
    fail "$(basename "$f") uses the $used singleton from another directory but
  does not 'import qs.Services'. That resolves at call time, so the shell loads
  clean and the feature fails on first use."
    # Comments are stripped first: naming a singleton in a comment is not
    # using it, and a note like "Keys match SettingsService.open(page)" is
    # exactly the kind of prose this file is full of.
  done < <(sed 's|//.*||' "$f" \
    | grep -oE '\b[A-Z][A-Za-z]*(Service|Manager|Store|Server|Actions)\.' | tr -d '.' | sort -u)
done < <(find "$src" -name '*.qml')

# --------------------------------------------------------------------------
# Every QML file the shell ships has to be reachable from shell.qml's imports.
# A component in a directory nothing imports loads only by accident of being a
# sibling, which is exactly how a file ends up working in one place and
# "unavailable" in another.
# --------------------------------------------------------------------------
while read -r dir; do
  rel=${dir#"$src/"}
  [[ $rel == "$src" || -z $rel ]] && continue
  mod=qs.${rel//\//.}
  # Assets and scripts are not QML modules; Theme and Common are imported by
  # nearly every file rather than by shell.qml.
  case $rel in Assets*|scripts*|bin*|docs*|Theme|Common) continue ;; esac
  grep -rqF "import $mod" "$src" && continue
  # A standalone entry point is loaded by path rather than imported, by a
  # script or a launcher. Those are fine; a module nothing reaches at all is not.
  entry=0
  while read -r q; do
    grep -rqF "$(basename "$q")" "$src"/bin "$src"/scripts "$here/.." --include='*.sh' \
      --include='*.lua' --include='*.py' --include='PKGBUILD' 2>/dev/null && entry=1
  done < <(find "$dir" -maxdepth 1 -name '*.qml')
  ((entry)) \
    || fail "no file imports $mod and nothing launches it by path, so the QML in
  $rel is only reachable by accident of directory adjacency"
done < <(find "$src" -mindepth 1 -type d -not -path '*/Assets/*')

# --------------------------------------------------------------------------
# Common/Icon.qml builds its source url from a bare name, so a name with no
# svg behind it is not an error anywhere -- Image fails to load, MultiEffect
# paints nothing, and the glyph is simply absent. A transport button with no
# glyph on it is still a 26px click target, so it does not even leave a hole.
# Only literal names can be checked; the conditional ones are ternaries over
# literals, so both branches are picked up.
# --------------------------------------------------------------------------
# Two sources, and no others: `name:` written INSIDE an Icon block (tracked by
# brace depth, because `name:` also means a popover's identity and a launcher
# provider's label), and any `icon:` property, which in this shell only ever
# feeds an Icon.name. Only the value up to the next `;` is read, so the
# `icon: "scan"; label: "region"` one-liners do not contribute their labels.
# A `name:`/`icon:` that opens a block is skipped -- OsdPill picks its glyph
# with a switch, and the case labels in it are OSD kinds, not icon names.
missing=()
while read -r name; do
  [[ -f $src/Assets/icons/$name.svg ]] || missing+=("$name")
done < <(find "$src" -name '*.qml' -exec awk '
  # Every string literal in `value`, which is one property assignment: either a
  # bare "name" or a ternary over two of them.
  function emit(value,   rest) {
    if (value ~ /^[[:space:]]*\{/) return   # a block, not an expression
    rest = value
    while (match(rest, /"[a-z0-9-]+"/)) {
      print substr(rest, RSTART + 1, RLENGTH - 2)
      rest = substr(rest, RSTART + RLENGTH)
    }
  }
  # The assignment starting at `from`, cut at the `;` that ends it.
  function value(line, from,   v, semi) {
    v = substr(line, from)
    sub(/^[A-Za-z]+:/, "", v)
    semi = index(v, ";")
    return semi ? substr(v, 1, semi - 1) : v
  }
  {
    line = $0
    if (match(line, /(^|[^A-Za-z])Icon[[:space:]]*\{/)) { inIcon = 1; depth = 0 }
    if (match(line, /^[[:space:]]*icon:/))
      emit(value(line, RSTART + RLENGTH - length("icon:")))
    else if (inIcon && match(line, /(^|[[:space:]{])name:/))
      emit(value(line, RSTART + RLENGTH - length("name:")))
    if (inIcon) {
      opens = gsub(/\{/, "{", line); closes = gsub(/\}/, "}", line)
      depth += opens - closes
      if (depth <= 0) inIcon = 0
    }
  }
' {} + | sort -u)
if ((${#missing[@]})); then
  fail "Icon name(s) with no Assets/icons/<name>.svg behind them. Icon draws
  nothing at all for these -- no warning, no placeholder, just a glyph that is
  not there: ${missing[*]}"
fi

# --------------------------------------------------------------------------
# PopoverManager holds ONE name at a time, so a name claimed by two popovers
# means both windows map on the same click. Each then asks Hyprland for a focus
# grab, the second request cancels the first, HyprlandFocusGrab.onCleared calls
# PopoverManager.close(), and both panels vanish. What the user sees is a
# popover that flashes and disappears; what the log says is nothing at all.
#
# This happened for real: the battery popover was named "power", which the
# session menu behind the bar's power button already answered to.
# --------------------------------------------------------------------------
# GlassPopover subclasses declare `name:`; PowerDropdown is a PopupSurface of
# its own and declares the same identity as `open: ... === "x"`.
names=$(
  # Exactly two spaces: that is a property of the popover's own root object.
  # Anything deeper is a nested Icon, which uses `name` for its glyph.
  { grep -rh --include='*.qml' -E '^  name: "[a-z]+"$' "$src/Modules/Popovers" 2>/dev/null \
      | sed -E 's/.*"([a-z]+)".*/\1/'
    grep -rh --include='*.qml' -E 'open: PopoverManager\.current === "[a-z]+"' "$src" 2>/dev/null \
      | sed -E 's/.*=== "([a-z]+)".*/\1/'
  } | sort
)
dupes=$(printf '%s\n' "$names" | uniq -d)
if [[ -n $dupes ]]; then
  fail "two popovers answer to the same PopoverManager name, so one click maps
  both windows and their focus grabs cancel each other -- the panel flashes and
  vanishes with nothing in the log:\n$dupes"
fi

# The other half of the same mistake: a bar module that toggles a name no
# popover answers to is a button that visibly does nothing.
while read -r want; do
  printf '%s\n' "$names" | grep -qx "$want" \
    || fail "PopoverManager.toggle(\"$want\", ...) names a popover that does not
  exist, so the button it is on does nothing at all"
done < <(grep -rho --include='*.qml' -E 'PopoverManager\.toggle\("[a-z]+"' "$src" \
  | sed -E 's/.*\("([a-z]+)".*/\1/' | sort -u)

# --------------------------------------------------------------------------
# The wifi lists render NetworkService.otherNames, and only that. The two other
# things that can go in are both wrong: the device's own ObjectModel is safe to
# pass but arrives in NetworkManager's own order, which is not signal order at
# all, and a JS array of the WifiNetwork objects sorts fine and then segfaults
# the shell when one of them is destroyed between a rescan and the next
# regenerate. Names are copies: they sort, and the row looks its network back
# up.
# --------------------------------------------------------------------------
hits=$(grep -rn --include='*.qml' -E 'model:.*(networks|NetworkService\.others)\b' "$src" \
  | grep -v 'NetworkService\.otherNames' || true)
if [[ -n $hits ]]; then
  fail "a wifi Repeater takes the networks straight: the ObjectModel comes in
  NetworkManager's order, not signal order, and an array of the objects
  segfaults when one is destroyed mid-rescan. Use NetworkService.otherNames and
  NetworkService.byName():\n$hits"
fi

# --------------------------------------------------------------------------
# A layer surface anchored to all four edges is asking to cover the screen,
# and `exclusiveZone: 0` does NOT give it that: a zero zone reserves nothing
# but still RESPECTS what other surfaces reserved, so the bar's own zone
# (Theme.barMarginTop + Theme.barHeight) shortens the window by that much.
# Only ExclusionMode.Ignore opts out.
#
# The size is not a constant to check against: barMarginTop is a slider on the
# topbar settings page (0..32 over a 38px bar), so the zone is 38-70px and the
# error tracks the setting live.
#
# The symptom is never an error either. CaptureOverlay found it as regions
# grabbed above the rectangle drawn for them; the launcher wore it as a panel
# half the zone below centre, and the auth prompt as a 45% backdrop that
# stopped short of the bar -- a modal holding an exclusive keyboard grab with
# the bar left undimmed, and clickable, above it.
# --------------------------------------------------------------------------
while read -r f; do
  # Order varies between files, so match the four edges independently rather
  # than the whole line.
  grep -qE '^[[:space:]]*anchors[[:space:]]*\{.*\}' "$f" || continue
  while read -r line; do
    for edge in top bottom left right; do
      printf '%s\n' "$line" | grep -qE "\b$edge:[[:space:]]*true\b" || continue 2
    done
    grep -q 'exclusionMode' "$f" && continue
    fail "$(basename "$f") anchors a layer surface to all four edges without
  \`exclusionMode: ExclusionMode.Ignore\`. A zero exclusive zone still respects
  the bar's reservation, so the window is Theme.barMarginTop + Theme.barHeight
  shorter than the screen it means to cover -- silently, with nothing in the
  log, and by an amount the topbar margin slider changes:\n  $line"
  done < <(grep -hE '^[[:space:]]*anchors[[:space:]]*\{.*\}' "$f")
done < <(find "$src" -name '*.qml')

# --------------------------------------------------------------------------
# Two objects in one file may not share an `id`. QML reports "id is not
# unique", and like every other error here that fails the load of the file,
# everything that imports it, and so the whole shell -- ClockPill.qml carried a
# duplicated block for two days and the desktop came up with no bar at all.
#
# It got in through a merge, not through anyone writing it: the same component
# had been added on both sides of a branch, so the text merged cleanly into two
# copies of itself, ids included. That is invisible in a diff of either parent,
# which is why it wants a check rather than more care.
#
# Ids are matched at the start of a line so a string or comment mentioning one
# does not count. Inline components (`component Foo: ...`) do open a scope of
# their own, so a repeat across two of them would be legal -- the tree has none,
# and one reported by mistake is renamed more cheaply than this is worth
# parsing for.
# --------------------------------------------------------------------------
while read -r f; do
  # `|| true`: a file with no id at all is normal, and under pipefail an
  # empty grep would end the run with no output and a bare exit 1.
  dupes=$( { grep -oE '^[[:space:]]*id:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "$f" || true; } \
    | sed -E 's/.*id:[[:space:]]*//' | sort | uniq -d)
  [[ -z $dupes ]] && continue
  fail "$(basename "$f") declares the same id more than once, which is \"id is
  not unique\" and fails the whole configuration load, not just that object.
  Usually a block that got merged in twice -- check for a duplicated component
  before renaming anything:\n$(sed 's/^/  id: /' <<<"$dupes")"
done < <(find "$src" -name '*.qml')

# --------------------------------------------------------------------------
# The palette lives in ONE file. The default accent was a literal in seven
# independent places across five languages, and the copies had already
# drifted: the
# defaults table in hypr/conf/appearance.lua called itself identical to
# AppearanceStore's JsonAdapter while missing the inactiveBorder that
# conf/look-and-feel.lua consumes, and the greeter's accentSoft was a shade off
# the shell's. Nothing catches that -- every copy is individually valid, and the
# symptom is one surface wearing last year's crimson.
#
# So: no colour literal anywhere outside quickshell/c7shell/palette.json.
# git ls-files, because a file this cannot see is a file nobody reviews either.
#
# Exempt, and why:
#   palette.json                    the source
#   sddm/.../PaletteStore.qml       generated from it (tools/gen-palette-qml.py)
#   *.svg, *.md                     artwork and prose, not tokens
#   docs/diagrams/*.dot             diagram sources in the Graphviz house
#                                   palette, which is not the shell's
#   #000000 / #ffffff               not palette entries: the ends of a mixing
#                                   range and the plain black/white overlays
#   Common/Hex.js, and the
#   Settings selfcheck that loads it  the colour maths itself: the literals are
#                                   worked examples and test vectors for
#                                   normalise/fromHsv/toHsv, not tokens anything
#                                   paints with
#   a `palette-literal-ok` marker   a colour that is deliberately NOT the
#                                   palette's, e.g. a test probing what ink a
#                                   yellow accent gets. One per line, with the
#                                   reason next to it.
# --------------------------------------------------------------------------
hits=$(
  git -C "$here/.." ls-files -z \
    | { grep -zv -e '\.svg$' -e '\.md$' -e '^docs/diagrams/.*\.dot$' \
          -e '^quickshell/c7shell/palette\.json$' \
          -e '^sddm/themes/c7shell/PaletteStore\.qml$' \
          -e '^quickshell/c7shell/Common/Hex\.js$' \
          -e '^quickshell/c7shell/Modules/Settings/selfcheck\.mjs$' || true; } \
    | xargs -0 grep -nIE '#[0-9a-fA-F]{6}\b' 2>/dev/null \
    | grep -viE '#(000000|ffffff)\b' \
    | grep -v 'palette-literal-ok' || true
)
if [[ -n $hits ]]; then
  fail "colour literal outside quickshell/c7shell/palette.json. Every consumer
  reads that file -- the shell through Services/PaletteStore.qml, the greeter
  through the generated sddm/themes/c7shell/PaletteStore.qml, the exporter with
  json.load, and hypr/conf/appearance.lua with conf/json. A literal here is a
  copy, and the copies drift:\n$hits"
fi

# --------------------------------------------------------------------------
# The one palette that cannot read palette.json at all: hyprlang has no
# expansion and cannot parse JSON, so hyprlock.conf carries a block of
# defaults for a machine that has never run the exporter (see #92). It is
# sourced-over in every other case, which is exactly why a drift in it is
# invisible until somebody locks a fresh install and gets last year's crimson.
#
# Compared against what the exporter would write for the default accent and
# variant, which is what that machine would have had.
# --------------------------------------------------------------------------
if command -v python3 >/dev/null; then
  drift=$(python3 - "$here/.." <<'PYEOF' || true
import importlib.util, re, sys

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "export", f"{root}/quickshell/c7shell/scripts/c7shell-theme-export.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def variables(text):
    """$name = rgba(...) -> {name: value}, ignoring trailing comments."""
    return dict(re.findall(r"^\$(\w+)\s*=\s*(rgba\([0-9a-fA-F]+\))", text, re.M))


want = variables(mod.hyprlock_palette(mod.DEFAULT_ACCENT, mod.DEFAULTS["theme"]))
with open(f"{root}/hypr/hyprlock.conf", encoding="utf-8") as f:
    have = variables(f.read())

for name, value in sorted(want.items()):
    if name not in have:
        print(f"  ${name}: the exporter writes it, hyprlock.conf has no default")
    elif have[name] != value:
        print(f"  ${name}: hyprlock.conf says {have[name]}, the palette says {value}")
PYEOF
)
  if [[ -n $drift ]]; then
    fail "hypr/hyprlock.conf's fallback palette has drifted from the palette the
  exporter writes. It is only read on a machine that has never exported, so
  nothing else would ever notice:\n$drift"
  fi
fi

# --------------------------------------------------------------------------
# A component named from a directory the file does not import resolves only by
# accident of directory adjacency -- which is how a delegate lifted out of a
# page into a subdirectory keeps working in the editor and fails at load.
# quickshell builds a directory's qmldir from the STATIC imports it can see, so
# the failure is "unknown type" on a page nobody opened yet, and that aborts
# the whole configuration.
#
# Only names this repository actually ships are checked. A type with no
# <Name>.qml anywhere under the shell is QtQuick's or Quickshell's, and neither
# needs a qs.* import to resolve.
# --------------------------------------------------------------------------
if command -v python3 >/dev/null; then
  unreachable=$(python3 - "$src" <<'PYEOF' || true
import os, re, sys

src = sys.argv[1]

# Every component this repository ships, by type name -> the directories it
# lives in. A name in two directories is resolvable from either.
owners = {}
for dirpath, _, files in os.walk(src):
    for f in files:
        if f.endswith(".qml") and f[0].isupper():
            owners.setdefault(f[:-4], set()).add(dirpath)

USE = re.compile(r"^\s*(?:component\s+[A-Za-z0-9_]+:\s*)?([A-Z][A-Za-z0-9_]*)\s*\{")
INLINE = re.compile(r"^\s*component\s+([A-Za-z0-9_]+)\s*:")
IMPORT = re.compile(r"^import\s+qs\.([A-Za-z0-9_.]+)\s*$", re.M)

for dirpath, _, files in os.walk(src):
    for f in sorted(files):
        if not f.endswith(".qml"):
            continue
        path = os.path.join(dirpath, f)
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        # Comments out first: a type named in prose is not a type in use.
        body = re.sub(r"//.*", "", text)

        # Its own directory is an implicit import, and so is everything it asks
        # for by name.
        reachable = {dirpath}
        for mod in IMPORT.findall(text):
            reachable.add(os.path.join(src, *mod.split(".")))
        # Its own inline components, and itself.
        local = set(INLINE.findall(body)) | {f[:-4]}

        for line in body.split("\n"):
            m = USE.match(line)
            if not m:
                continue
            name = m.group(1)
            if name in local or name not in owners:
                continue
            if owners[name] & reachable:
                continue
            where = ", ".join(sorted(
                "qs." + os.path.relpath(d, src).replace("/", ".")
                for d in owners[name]))
            print(f"  {os.path.relpath(path, src)} uses {name}, which lives in {where}")
PYEOF
)
  if [[ -n $unreachable ]]; then
    fail "these files name a component from a directory they do not import, so it
  resolves by directory adjacency rather than by an import quickshell can see:
$unreachable"
  fi
fi


echo 'test-qml-hygiene.sh: all checks passed'
