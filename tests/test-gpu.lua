-- Loads conf/gpu.lua and the three files that ask it questions, against a
-- stubbed /sys, and asserts what each one does on a virtual GPU and on real
-- hardware. Run from the hypr config directory, so the modules' own
-- require("conf/...") resolves:
--
--   lua ../tests/test-gpu.lua      (from the package tree's hypr/)
--   lua test_gpu.lua               (from ~/.config/hypr)
--
-- The wallpaper is the reason this exists. hyprpaper aborts on a virtual GPU
-- rather than merely failing to draw (conf/gpu.lua carries the trace), so on
-- those machines it is left out of autostart and the shell paints instead --
-- and that decision reaches three separate files. Getting it right in one and
-- wrong in another is a desktop whose wallpaper setting silently does nothing,
-- which is exactly the bug this replaced.

local failures = 0

local function check(name, got, want)
  if got ~= want then
    io.stderr:write(("FAIL: %s\n  got:  %s\n  want: %s\n"):format(name, tostring(got), tostring(want)))
    failures = failures + 1
  end
end

-- Runs `fn` with /sys/class/drm/card0 reporting `driver`, and with every module
-- re-required so the answer is not cached from a previous case. nil = no card
-- at all, which is what a build chroot looks like.
local function withDriver(driver, fn)
  local realopen = io.open
  io.open = function(path, ...)
    if path:match("/sys/class/drm/card%d/device/uevent") then
      if driver == nil or not path:match("card0") then return nil end
      return {
        read = function() return ("DRIVER=%s\nPCI_ID=0000\n"):format(driver) end,
        close = function() end,
      }
    end
    -- The developer's own appearance.json must not decide whether this passes:
    -- look-and-feel only restores a wallpaper when one is set, so a machine
    -- with none would report "hyprpaper was not asked" for the right value and
    -- the wrong reason.
    if path:match("appearance%.json$") then
      return {
        read = function() return '{"wallpaper":"/home/test/Pictures/wall.png"}' end,
        close = function() end,
        lines = function() return function() return nil end end,
      }
    end
    return realopen(path, ...)
  end

  for _, mod in ipairs({ "conf/gpu", "conf/appearance", "conf/environment",
                        "conf/autostart", "conf/look-and-feel" }) do
    package.loaded[mod] = nil
  end

  local ok, err = pcall(fn)
  io.open = realopen
  if not ok then error(err, 0) end
end

-- A recording `hl`. `start` collects the callbacks registered for
-- hyprland.start so the autostart case can fire them itself.
local function stubHl()
  local rec = { env = {}, exec = {}, start = {} }
  _G.hl = {
    env = function(k, v) rec.env[k] = v end,
    exec_cmd = function(c) rec.exec[#rec.exec + 1] = c end,
    on = function(event, fn) if event == "hyprland.start" then rec.start[#rec.start + 1] = fn end end,
    config = function() end,
    animation = function() end,
    bind = function() end,
    monitor = function() end,
    get_monitors = function() return {} end,
    dsp = setmetatable({}, { __index = function() return function() end end }),
  }
  return rec
end

local function contains(haystack, needle)
  for _, s in ipairs(haystack) do if s:find(needle, 1, true) then return true end end
  return false
end

-- --- the detection itself --------------------------------------------------
for _, driver in ipairs({ "vmwgfx", "vboxvideo", "virtio_gpu" }) do
  withDriver(driver, function()
    local gpu = require("conf/gpu")
    check(driver .. " is virtual", gpu.virtual(), true)
    check(driver .. " wallpaper backend", gpu.wallpaper_backend(), "shell")
  end)
end

for _, driver in ipairs({ "amdgpu", "i915", "nouveau", "nvidia" }) do
  withDriver(driver, function()
    local gpu = require("conf/gpu")
    check(driver .. " is not virtual", gpu.virtual(), false)
    check(driver .. " wallpaper backend", gpu.wallpaper_backend(), "hyprpaper")
  end)
end

-- No /sys at all -- a chroot, or a kernel with no DRM. Guessing "virtual" there
-- would drop hyprpaper on machines that can run it perfectly well.
withDriver(nil, function()
  local gpu = require("conf/gpu")
  check("no drm card is not virtual", gpu.virtual(), false)
  check("no drm card wallpaper backend", gpu.wallpaper_backend(), "hyprpaper")
end)

-- --- what the three readers do with it -------------------------------------
local function autostartLine(driver)
  local line
  withDriver(driver, function()
    local rec = stubHl()
    require("conf/autostart")
    for _, fn in ipairs(rec.start) do fn() end
    for _, cmd in ipairs(rec.exec) do
      if cmd:find("c7shell-session", 1, true) then line = cmd end
    end
  end)
  return line or ""
end

check("virtual GPU: hyprpaper is not autostarted",
  autostartLine("vmwgfx"):find("hyprpaper", 1, true) ~= nil, false)
check("virtual GPU: the shell still is",
  autostartLine("vmwgfx"):find("c7shell-session", 1, true) ~= nil, true)
check("virtual GPU: hypridle still is",
  autostartLine("vmwgfx"):find("hypridle", 1, true) ~= nil, true)
check("real GPU: hyprpaper is autostarted",
  autostartLine("amdgpu"):find("hyprpaper", 1, true) ~= nil, true)
check("real GPU: hypridle still is",
  autostartLine("amdgpu"):find("hypridle", 1, true) ~= nil, true)

local function envFor(driver)
  local env
  withDriver(driver, function()
    local rec = stubHl()
    require("conf/environment")
    env = rec.env
  end)
  return env
end

-- The shell reads this to decide whether to paint the wallpaper itself. Unset
-- means hyprpaper, so a shell started outside this session behaves as before.
check("virtual GPU: the shell is told it owns the wallpaper",
  envFor("vmwgfx").C7SHELL_WALLPAPER, "shell")
check("virtual GPU: clients get llvmpipe",
  envFor("vmwgfx").LIBGL_ALWAYS_SOFTWARE, "1")
check("real GPU: nothing is said about the wallpaper",
  envFor("amdgpu").C7SHELL_WALLPAPER, nil)
check("real GPU: no software GL",
  envFor("amdgpu").LIBGL_ALWAYS_SOFTWARE, nil)

-- look-and-feel restores the wallpaper at config load. On a virtual GPU that
-- would be a request to a process that is not running.
local function restoresWallpaper(driver)
  local restored
  withDriver(driver, function()
    local rec = stubHl()
    require("conf/look-and-feel")
    restored = contains(rec.exec, "hyprctl hyprpaper wallpaper")
  end)
  return restored
end

check("real GPU: the wallpaper is restored at config load", restoresWallpaper("amdgpu"), true)
check("virtual GPU: nothing is asked of a dead hyprpaper", restoresWallpaper("vmwgfx"), false)

if failures > 0 then
  io.stderr:write(("\n%d check(s) failed\n"):format(failures))
  os.exit(1)
end
print("PASS: gpu backend selection")
