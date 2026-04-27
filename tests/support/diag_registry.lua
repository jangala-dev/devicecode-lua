return {
  plugins = {
    device = require 'tests.support.diag_plugins.device',
    fabric = require 'tests.support.diag_plugins.fabric',
    config = require 'tests.support.diag_plugins.config',
    obs    = require 'tests.support.diag_plugins.obs',
    rpc    = require 'tests.support.diag_plugins.rpc',
  },
  profiles = {
    device_stack = require 'tests.support.diag_profiles.device_stack',
    fabric_stack = require 'tests.support.diag_profiles.fabric_stack',
  },
}
