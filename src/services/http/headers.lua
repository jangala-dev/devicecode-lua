-- services/http/headers.lua
-- Public header boundary.  Backend-specific construction lives in transport.
return require 'services.http.transport.headers'
