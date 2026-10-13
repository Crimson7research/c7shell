#!/usr/bin/env bash
# Screenshot checks for the VM setup test. Sourced, not executed.
#
# Deliberately coarse: "something is drawn" and "the bar strip is not the
# wallpaper". A pixel-exact comparison would fail on every theme tweak.

_vt_mean() { magick "$1" ${2:+-crop "$2" +repage} -colorspace gray -format '%[fx:mean]' info:; }

screen_not_uniform() {
  local sd
  sd=$(magick "$1" -colorspace gray -format '%[fx:standard_deviation]' info:) || return 1
  awk -v s="$sd" 'BEGIN { exit !(s > 0.01) }'
}

screen_regions_differ() {
  local a b
  a=$(_vt_mean "$1" "$2") && b=$(_vt_mean "$1" "$3") || return 1
  awk -v a="$a" -v b="$b" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d > 0.05) }'
}

screen_bar_drawn() {
  local w h
  read -r w h < <(magick "$1" -format '%w %h\n' info:) || return 1
  screen_regions_differ "$1" "${w}x40+0+0" "${w}x40+0+$((h / 2))"
}
