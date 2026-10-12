return {
  -- Colorscheme (catppuccin to match your desktop)
  {
    "catppuccin/nvim",
    name = "catppuccin",
    priority = 1000,
    config = function()
      -- A desktop theme that carries Catppuccin colour overrides (extra.nvim
      -- in its theme.json, e.g. wallpapers/_presets/soviet.json, switched by
      -- scripts/theme/theme) recolours Mocha; otherwise plain Mocha.
      local ok, json = pcall(function()
        local f = io.open((os.getenv("XDG_CACHE_HOME") or (os.getenv("HOME") .. "/.cache")) .. "/wallpaper_theme/current.json")
        if not f then return nil end
        local s = f:read("*a")
        f:close()
        return vim.json.decode(s)
      end)
      local over = ok and json and json.extra and json.extra.nvim
      if type(over) == "table" then
        require("catppuccin").setup({ color_overrides = { mocha = over } })
      end
      vim.cmd.colorscheme("catppuccin-mocha")
    end,
  },
}
