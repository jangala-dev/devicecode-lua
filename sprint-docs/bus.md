would be great to have a publish method that can update multiple endpoints when provided with a table

eg buscon:publish_multi('foo/bar', {'hee'={'ha'=42},'ha'=true})

sub = buscon:subscribe('foo/bar/hee/ha')
sub.nextmsg()
> 42