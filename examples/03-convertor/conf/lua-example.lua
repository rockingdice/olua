module "example"

path "src"

headers [[
#include "Example.h"
#include "xlua.h"
]]

include "../common/lua-object.lua"

typedef "example::Identifier"
    .decltype "std::string"
typedef "example::Color"
typedef "example::vector"

typeconv "example::Point"

typeconf "example::Node"