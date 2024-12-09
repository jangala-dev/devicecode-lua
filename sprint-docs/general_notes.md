## Message builder
Building messages for the bus can take up a lot of lines and reduce readability, perhaps a message builder could be 
used for repetative messaging.

How would it work?
somthing like this:
```lua
local msg_builder = mb.new(topic, retained)
msg_builder:set_payload({
    table1 = {
        const_field1 = <blah>,
        var_field1 = msg_builder:arg() -- This would be arg 1??
    },
    var_field2 = msg_builder:arg() -- This would be arg 2??
})
-- somewhere further on, perhaps in multiple places
local msg = msg_builder:make(var1, var2)
bus_conn:publish(msg)
```
Would the arg order be so easy to know???
i haven't condisdered anything past this in terms of implemetation :)