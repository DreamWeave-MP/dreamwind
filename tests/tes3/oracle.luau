--!strict
-- Whether the native binding is there to compare the port with live: a runtime with jess's API.

local jess = (_G :: any).jess
return jess ~= nil and jess.plugin ~= nil
