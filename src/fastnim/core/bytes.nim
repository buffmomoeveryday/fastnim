## Binary byte-size helpers for limits and upload configuration.
##
## Values use powers of 1024, matching typical file and buffer limits:
## ``1.MB == 1_048_576``. Prefer ``.KiB`` / ``.MiB`` / ``.GiB`` for IEC names;
## ``.KB`` / ``.MB`` / ``.GB`` are the same binary units in shorter form.
##
## Example::
##
##   maxRequestSize = 6.MB
##   maxFileSize = 200.KiB

template bytes*(n: SomeInteger): int64 =
  ## Returns ``n`` as an ``int64`` byte count.
  int64(n)

template KiB*(n: SomeInteger): int64 =
  ## ``n`` kibibytes (``n * 1024``).
  int64(n) * 1024'i64

template MiB*(n: SomeInteger): int64 =
  ## ``n`` mebibytes (``n * 1024²``).
  int64(n) * 1024'i64 * 1024'i64

template GiB*(n: SomeInteger): int64 =
  ## ``n`` gibibytes (``n * 1024³``).
  int64(n) * 1024'i64 * 1024'i64 * 1024'i64

template KB*(n: SomeInteger): int64 =
  ## Alias for ``n.KiB``.
  n.KiB

template MB*(n: SomeInteger): int64 =
  ## Alias for ``n.MiB``.
  n.MiB

template GB*(n: SomeInteger): int64 =
  ## Alias for ``n.GiB``.
  n.GiB
