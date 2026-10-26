# The repository config disables Nimble's package path. Skip it and compile
# this example against the FastNim checkout, which includes the ORM.
switch("skipParentCfg")
switch("path", thisDir() & "/../../src")
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
