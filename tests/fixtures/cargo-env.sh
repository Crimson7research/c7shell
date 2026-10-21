# shellcheck shell=bash
# Sourced before cargo builds the plugin workspace. It makes the build
# environment one the workspace links in, whatever ran us: makepkg's
# check() in particular, which sets two things the workspace cannot take.
#
# RUSTFLAGS: when set, cargo ignores plugin/.cargo/config.toml's rustflags,
# and with them the rust-lld pin. qt-build-utils then picks gold, which drops
# cxx-qt's initialisers. So the pin is added to RUSTFLAGS, once.
#
# -flto*: GCC then writes cxx-qt's generated C++ as GCC LTO objects, which
# ld.lld cannot read, so every bridge symbol is undefined. Those flags are
# removed from CFLAGS, CXXFLAGS and LDFLAGS; everything else in them stays.

c7_lld_pin='-C link-arg=-fuse-ld=lld'
if [[ -n ${RUSTFLAGS:-} && $RUSTFLAGS != *"$c7_lld_pin"* ]]; then
  export RUSTFLAGS="$RUSTFLAGS $c7_lld_pin"
fi
unset c7_lld_pin

# c7_without_lto VALUE -- VALUE with every -flto and -flto=... word removed.
c7_without_lto() {
  local word out=()
  for word in $1; do
    [[ $word == -flto || $word == -flto=* ]] || out+=("$word")
  done
  printf '%s' "${out[*]}"
}
for c7_var in CFLAGS CXXFLAGS LDFLAGS; do
  if [[ -n ${!c7_var:-} ]]; then
    export "$c7_var=$(c7_without_lto "${!c7_var}")"
  fi
done
unset c7_var
