package.path = "../../../?.lua;../../../?/init.lua;" .. package.path

require "olua.tools"

autoconf "conf/clang-args.lua"
autoconf "conf/lua-callback.lua"

-- export lua bindings
dofile "autobuild/make.lua"