import std/assertions

import fastnim

doAssert 1.bytes == 1
doAssert 200.KB == 200 * 1024
doAssert 200.KiB == 200.KB
doAssert 5.MB == 5 * 1024 * 1024
doAssert 5.MiB == 5.MB
doAssert 1.GB == 1024'i64 * 1024 * 1024
doAssert 1.GiB == 1.GB
doAssert 6.MB == 6'i64 * 1024 * 1024
