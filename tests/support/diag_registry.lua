return {
  plugins = {
    update = require 'tests.support.diag_plugins.update',
    device = require 'tests.support.diag_plugins.device',
    fabric = require 'tests.support.diag_plugins.fabric',
    ui     = require 'tests.support.diag_plugins.ui',
    config = require 'tests.support.diag_plugins.config',
    obs    = require 'tests.support.diag_plugins.obs',
    rpc    = require 'tests.support.diag_plugins.rpc',
  },
  profiles = {
    update_stack = require 'tests.support.diag_profiles.update_stack',
    device_stack = require 'tests.support.diag_profiles.device_stack',
    fabric_stack = require 'tests.support.diag_profiles.fabric_stack',
    ui_stack     = require 'tests.support.diag_profiles.ui_stack',
  },
}
