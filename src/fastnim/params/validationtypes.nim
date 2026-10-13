## Shared validation result types used by input extractors and validators.
##
## Keeping these types independent from request parsing allows query, body,
## and form inputs to report the same structured field errors.

type
  FieldError* = object ## One input or value-constraint failure at a specific location.
    location*: seq[string] ## Path below the input source, e.g. ``@["user", "email"]``.
    code*: string ## Stable rule or parsing code, e.g. ``"required"``.
    message*: string ## Human-readable message for this field.

  ValidationResult* = object ## Accumulated input parsing or value-constraint failures.
    errors*: seq[FieldError] ## One entry per failed field or constraint.

func field*(error: FieldError): string {.inline, raises: [].} =
  ## Returns the final field or index in an error location, or ``""`` at the root.
  if error.location.len == 0:
    ""
  else:
    error.location[^1]

proc initValidationResult*(): ValidationResult {.inline, raises: [].} =
  ## Creates an empty, valid validation result.
  ValidationResult(errors: @[])

proc addError*(
    result: var ValidationResult, location: openArray[string], code, message: string
) {.raises: [].} =
  ## Records one error at ``location``.
  result.errors.add(FieldError(location: @location, code: code, message: message))

proc addError*(
    result: var ValidationResult, field, code, message: string
) {.raises: [].} =
  ## Records one field error and marks ``result`` as invalid.
  result.addError([field], code, message)

proc isValid*(validation: ValidationResult): bool {.inline, raises: [].} =
  ## Returns whether ``validation`` holds no field errors.
  validation.errors.len == 0

proc mergeErrors*(
    result: var ValidationResult, other: ValidationResult
) {.raises: [].} =
  ## Folds ``other`` into ``result``.
  for error in other.errors:
    result.errors.add(error)

proc withPrefix*(
    validation: ValidationResult, prefix: openArray[string]
): ValidationResult {.raises: [].} =
  ## Returns ``validation`` with ``prefix`` prepended to every error location.
  result = initValidationResult()
  for error in validation.errors:
    result.addError(@prefix & error.location, error.code, error.message)
