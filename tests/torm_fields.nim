import std/[json, os, tempfiles]
import chronos/unittest2/asynctests
import fastnim/orm

type Status = enum
  statusDraft
  statusPublished

model Product:
  name:
    CharField()
  price:
    DecimalField(maxDigits: 6, decimalPlaces: 2, default: decimal("0.00"))
  released:
    DateField(autoNowAdd: true)
  opensAt:
    TimeField()
  warranty:
    DurationField()
  extra:
    JSONField(default: """{"ok":true}""")
  blob:
    BinaryField(maxLength: 8, null: true)
  cover:
    FileField(uploadToDir: "covers/books", maxLength: 300)
  email:
    EmailField(null: true)
  site:
    URLField()
  slug:
    SlugField(unique: true)
  level:
    IntegerField(choices: [1, 2, 3], default: 1)
  status:
    CharField(choices: Status, default: statusDraft)

proc freshDb(): Future[(Database, string)] {.async.} =
  let dir = createTempDir("fastorm_fields_", "_test")
  let db = await openDatabase(dir / "test.sqlite3")
  discard makeMigrations(dir / "migrations")
  discard await db.migrate(dir / "migrations")
  return (db, dir)

proc cleanup(db: Database, dir: string) {.async.} =
  await db.close()
  removeDir(dir)

suite "field types":
  test "constructors normalize and reject bad values":
    check decimal("00.50") == decimal("0.50")
    expect ValueError:
      discard decimal("1e2")
    expect ValueError:
      discard initDate(2023, 2, 29)
    check initDate(2024, 2, 29).day == 29
    expect ValueError:
      discard initTimeOfDay(24, 0, 0)
    check timeSpanSeconds(2) == timeSpan(2_000_000)
    check FileField(uploadToDir = "covers/books/").uploadToDir == "covers/books"
    expect ValueError:
      discard FileField(maxLength = 0)
    expect ValueError:
      discard FileField(uploadToDir = "/absolute")
    expect ValueError:
      discard FileField(uploadToDir = "covers/../private")

  test "metadata records kinds, formats, and choices":
    let m = modelMeta(Product)
    check m.fields[m.findField("price")].kind == fkDecimal
    check m.fields[m.findField("price")].maxDigits == 6
    check m.fields[m.findField("email")].format == ffEmail
    check m.fields[m.findField("email")].kind == fkChar
    check m.fields[m.findField("blob")].kind == fkBinary
    check m.fields[m.findField("cover")].kind == fkFile
    check m.fields[m.findField("cover")].uploadToDir == "covers/books"
    check m.fields[m.findField("cover")].maxLength == 300
    check m.fields[m.findField("level")].choices.len == 3
    let made = newProduct()
    check made.price == decimal("0.00")
    check made.status == statusDraft
    check made.extra["ok"].getBool

  asyncTest "values round-trip through SQLite":
    let (db, dir) = await freshDb()
    let info = await db.query("PRAGMA table_info(product)")
    var types: seq[string]
    for row in info.rows:
      if row[1].s == "price":
        types.add row[2].s
      if row[1].s == "warranty":
        types.add row[2].s
      if row[1].s == "blob":
        types.add row[2].s
    check "TEXT" in types
    check "INTEGER" in types
    check "BLOB" in types
    var item = newProduct()
    item.name = "Ada"
    item.price = decimal("12.50")
    item.opensAt = initTimeOfDay(9, 30, 0, 5)
    item.warranty = timeSpanSeconds(2)
    item.extra = parseJson("""{"n":1}""")
    item.blob = some(@[byte 1, byte 2, byte 3])
    item.cover = "covers/books/ada.jpg"
    item.email = some("ada@example.com")
    item.site = "https://example.com/a"
    item.slug = "ada-book"
    item.level = 2
    item.status = statusPublished
    await item.save()
    let loaded = (await Product.objects.get(slug = "ada-book")).get
    check loaded.price == decimal("12.50")
    check loaded.released.year > 0
    check loaded.opensAt == initTimeOfDay(9, 30, 0, 5)
    check loaded.warranty == timeSpanSeconds(2)
    check loaded.extra["n"].getInt == 1
    check loaded.blob.get == @[byte 1, byte 2, byte 3]
    check loaded.cover == "covers/books/ada.jpg"
    check loaded.email.get == "ada@example.com"
    check loaded.status == statusPublished
    let found = await Product.objects.filter(status = statusPublished).all()
    check found.len == 1
    let encoded = parseJson(loaded.serialize())
    check encoded["price"].getStr == "12.50"
    check encoded["extra"]["n"].getInt == 1
    check encoded["warranty"].getInt == 2_000_000
    check encoded["cover"].getStr == "covers/books/ada.jpg"
    await cleanup(db, dir)

  asyncTest "validation rejects bad field values before writing":
    let (db, dir) = await freshDb()
    var item = newProduct()
    item.name = "Ada"
    item.price = decimal("12345.678")
    item.opensAt = initTimeOfDay(1, 0, 0)
    item.site = "notaurl"
    item.slug = "bad slug"
    item.email = some("ada")
    item.level = 9
    expect ValidationError:
      await item.save()
    check (await Product.objects.count()) == 0
    item.price = decimal("1.50")
    item.site = "https://example.com"
    item.slug = "ada"
    item.email = some("ada@example.com")
    item.level = 1
    item.blob = some(@[byte 0, 1, 2, 3, 4, 5, 6, 7, 8])
    expect ValidationError:
      await item.save()
    check (await Product.objects.count()) == 0
    await cleanup(db, dir)
