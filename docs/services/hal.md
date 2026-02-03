# HAL
## File Structure
- hal.lua
- hal

  - backends <-- portability layer: choose a provider implementation per device family
    - uart
      - provider.lua <-- selects UART provider (fibers, ubus, etc)
      - providers
        - fibers_core
          - init.lua

    - modem
      - provider.lua <-- selects modem provider (OpenWrt ModemManager, testing, etc)
      - iface.lua <-- the modem-backend interface contract (documented + validated)
      - providers
        - openwrt_mm
          - init.lua <-- constructs a backend that implements modem/iface.lua
          - mmcli.lua <-- executor: mmcli bindings
          - at.lua <-- ModemManager-specific AT bridge (if needed)
        - some_other_software
          - init.lua

  - drivers <-- domain logic + stable capability surface
    - modem
      - driver.lua <-- assembles base + mode + model strategies
      - mode.lua
      - model.lua
      - mode
        - qmi.lua
        - mbim.lua
      - model
        - quectel.lua
        - fibcocom.lua

  - managers <-- owns lifecycles, supervision, (re)announce capabilities
    - modemcard.lua

  - types <-- structured tables + validation
    - core.lua
    - capabilities.lua
    - external.lua
    - modem.lua

  - resources.lua <-- loads managers based on hardware target (declarative wiring)
  - resources
    - bigbox_v1_cm.lua
    - bigbox_ss.lua
