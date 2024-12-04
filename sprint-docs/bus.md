would be great to have a publish method that can update multiple endpoints when provided with a table

eg buscon:publish_multi('foo/bar', {'hee'={'ha'=42},'ha'=true})

sub = buscon:subscribe('foo/bar/hee/ha')
sub.nextmsg()
> 42

the bus currently cannot guarantee that a published message will be delivered due to the subscription queue needing to block if more than one item is appended to it on the same fiber during one execution period. This is because the put op on the queue is performed with 
```lua
sub:put_op():perform_alt(function ()
    -- Logging here
end)
```
which means a blocking call to the queue will not deliver the message.