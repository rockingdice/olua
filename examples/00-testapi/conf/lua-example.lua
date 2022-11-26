module "example"

path "src"

headers [[
#include "Example.h"
#include "olua-custom.h"
]]

excludetype 'example::ExcludeType'

import "../common/lua-object.lua"

typeconf "example::ClickCallback"
typeconf 'example::Type'
typeconf 'example::Point'
    .packable 'true'
typeconf "example::Hello"
    .func 'convertPoint' .arg1 '@pack'
