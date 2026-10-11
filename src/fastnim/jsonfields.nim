## Field-name customization for FastNim JSON models.

template jsonName*(name: static[string]) {.pragma.}
  ## Renames an object field when FastNim encodes, decodes, or documents JSON.
