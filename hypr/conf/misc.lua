----------------
----  MISC  ----
----------------

hl.config({
    misc = {
        force_default_wallpaper = 1,    -- Set to 0 or 1 to disable the anime mascot wallpapers
        disable_hyprland_logo   = true, -- If true disables the random hyprland logo / anime girl background. :(
        -- If hyprlock crashes, the session stays locked; this lets a new
        -- hyprlock (SUPER+L, which works while locked) take it over.
        allow_session_lock_restore = true,
    },
})
