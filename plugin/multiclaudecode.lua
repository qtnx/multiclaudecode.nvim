if vim.g.loaded_multiclaudecode then
  return
end
vim.g.loaded_multiclaudecode = true

require("multiclaudecode").setup()