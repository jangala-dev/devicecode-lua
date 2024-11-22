# Service structure
## service spawning
A service is created using service.spawn() which will follow the general form
- Publish service active under `<service_name>/health`
- Run service start function with arguments of bus connection and context (start function should be non-blocking)
- Create a shutdown fiber
- Shutdown fiber will 
    - wait for a shutdown message on `<service_name>/control/shutdown`
    - check all fibers' state on `<service_name>/health/fibers/+`
    - track which fibers are not showing 'disabled' state yet
    - once all fibers are showing disabled it will publish service state disabled and close

## fiber spawning
A service fiber is a fiber that is spawned with tracking features, spawning follows the steps
- Publish 'fiber init' under `<service_name>/health/fibers/<fiber_name>`
- create fiber and pass context with cancel and values fiber_name and service_name
- when fiber spins up 
    - publish 'fiber active'
    - run the given function with ctx as argument (this function should be blocking)
    - when given function returns, publish 'fiber disabled'