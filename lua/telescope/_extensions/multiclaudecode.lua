local telescope = require("telescope")
local telescope_multiclaudecode = require("multiclaudecode.telescope")

return telescope.register_extension({
  exports = {
    sessions = telescope_multiclaudecode.sessions_picker,
    multiclaudecode = telescope_multiclaudecode.sessions_picker,
  },
})