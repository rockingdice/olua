package.path = "../../../?.lua;../../../?/init.lua;" .. package.path

OLUA_AUTO_EXPORT_PARENT = true

require "olua.tools"

autoconf "conf/clang-args.lua"
autoconf "conf/lua-example.lua"
