return {
  "nvim-treesitter/nvim-treesitter",
  build = ":TSUpdate",
  config = function()
    require("nvim-treesitter").setup({
      ensure_installed = { "rust", "lua", "toml", "bash", "json", "markdown", "qmljs" },
      highlight = { enable = true },
      indent = { enable = true },
    })
  end,
}
