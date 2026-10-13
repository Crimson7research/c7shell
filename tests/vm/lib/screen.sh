#!/usr/bin/env bash
# Screenshot checks for the VM setup test. Sourced, not executed.
#
# Deliberately coarse: "something is drawn". Whether the bar is up is asked
# of Hyprland (lib/session.sh), not guessed from pixels: on the dark theme
# the bar and the wallpaper differ by under 1% in mean brightness.

screen_not_uniform() {
  local sd
  sd=$(magick "$1" -colorspace gray -format '%[fx:standard_deviation]' info:) || return 1
  awk -v s="$sd" 'BEGIN { exit !(s > 0.01) }'
}
