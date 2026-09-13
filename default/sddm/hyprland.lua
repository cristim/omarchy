-- Minimal Hyprland config for the SDDM Wayland greeter.
-- SDDM starts the greeter itself after the compositor is ready.
hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },

  animations = {
    enabled = false,
  },
})

-- The greeter opens one window per output, each with its own QML engine, but
-- only the focused one receives keystrokes: the rest show a password field that
-- never fills in. Windows map after the compositor starts and the last one to
-- map takes focus, so on a multi-head machine the prompt answers on whichever
-- display happened to come up last. Prefer the built-in panel, falling back to
-- the first output so this works on desktops too.
--
-- hyprctl parses dispatch arguments as lua, so "focusmonitor eDP-1" and
-- "focusmonitor 0" both silently do nothing.
hl.on("hyprland.start", function()
  hl.exec_cmd([[
    for _ in $(seq 1 80); do
      hyprctl clients | grep -q sddm-greeter || { sleep 0.25; continue; }
      name=$(hyprctl monitors | awk '/^Monitor eDP/{print $2; exit}')
      [ -n "$name" ] || name=$(hyprctl monitors | awk '/^Monitor /{print $2; exit}')
      [ -n "$name" ] && hyprctl dispatch "hl.dsp.focus({ monitor = \"$name\" })"
      break
    done
  ]])
end)
