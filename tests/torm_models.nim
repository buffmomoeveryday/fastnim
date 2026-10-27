import std/[json, jsonutils, unittest, strutils, sequtils]
import fastnim/orm

proc titleCase(value: string): string =
  if value.len > 0 and value[0].isLowerAscii: "must start with a capital letter" else: ""

model Base {.abstract.}:
  id:
    UUIDField(primaryKey: true)
  createdAt:
    DateTimeField(autoNowAdd: true)
  title:
    CharField(maxLength: 100)

model Person = ref Base:
  name:
    CharField(maxLength: 19, minLength: 2, validator: titleCase)
  title:
    CharField(maxLength: 10)

model Employee = ref Person:
  salary:
    IntegerField(default: 1000)

model Tag {.table: "tags".}:
  label:
    CharField(unique: true)

model Node:
  parent:
    ForeignKey(Node, onDelete: SetNull, null: true)
  name:
    TextField(null: true)

model Publishable {.abstract.}:
  title:
    CharField()
  published:
    BooleanField()
  createdAt:
    DateTimeField()
  Meta:
    ordering:
      ["-createdAt", "title"]
    indexes:
      Index(fields: ["title", "published"], name: "{model}_title_pub")

model Story = ref Publishable:
  Meta:
    table:
      "stories"
    uniqueTogether:
      ["title", "published"]

model Slug:
  title:
    CharField(index: true)
  slug:
    CharField()
  Meta:
    ordering:
      ["title"]
    indexes:
      Index(fields: ["-slug"], name: "slug_recent")

suite "model metadata":
  test "fields are typed Nim values":
    let p = Person(name: "Ada")
    check p.name is string
    check p.id is UUID
    check p.createdAt is Time
    check Node().parentId is Option[int]
    check Node().name is Option[string]

  test "abstract base contributes fields but no table":
    check not compiles(modelMeta(Base))
    check not compiles(Base.objects)
    for m in registeredModels():
      check m.name != "Base"

  test "inheritance merges fields in declaration order":
    let m = modelMeta(Person)
    var names: seq[string]
    for f in m.fields:
      names.add f.name
    check names == @["id", "createdAt", "title", "name"]
    check m.table == "person"
    check m.parent == "Base"
    check m.pkField.name == "id"

  test "child overrides apply only to the child":
    check modelMeta(Person).fields[modelMeta(Person).findField("title")].maxLength == 10

  test "multi-level inheritance uses Nim subtyping":
    let e = Employee(name: "Grace", salary: 5)
    check e of Person
    var names: seq[string]
    for f in modelMeta(Employee).fields:
      names.add f.name
    check names == @["id", "createdAt", "title", "name", "salary"]
    check modelMeta(Employee).table == "employee"

  test "automatic integer primary key and table pragma":
    let m = modelMeta(Tag)
    check m.table == "tags"
    check m.pkField.name == "id"
    check m.pkField.kind == fkInteger
    check m.fields[1].unique

  test "foreign key metadata":
    let f = modelMeta(Node).fields[modelMeta(Node).findField("parent")]
    check f.kind == fkForeignKey
    check f.column == "parent_id"
    check f.targetTable == "node"
    check f.targetKind == fkInteger
    check f.onDelete == SetNull

  test "defaults are applied by the generated constructor":
    check newEmployee().salary == 1000
    check Employee().salary == 0

  test "Meta indexes, ordering, and table are inherited":
    let story = modelMeta(Story)
    check story.table == "stories"
    check story.ordering == @["-created_at", "title"]
    var names: seq[string]
    for ix in story.indexes:
      names.add ix.name
    check names == @["story_title_pub", "stories_title_published_uniq"]
    check story.indexes[1].unique
    let slug = modelMeta(Slug)
    check slug.ordering == @["title"]
    check slug.indexes.len == 1
    check slug.indexes[0].name == "slug_recent"
    check slug.indexes[0].columns == @["slug"]
    check slug.indexes[0].descending == @[true]
    var schemaNames: seq[string]
    for ix in snapshotOf([modelMeta(Slug)]).tables[0].indexes:
      schemaNames.add ix.name
    check "slug_title_idx" in schemaNames
    check "slug_recent" in schemaNames

  test "validation":
    check validate(Person(name: "Ada", title: "Dr")).len == 0
    let issues = validate(Person(name: "a", title: "much too long title"))
    var fields: seq[string]
    for i in issues:
      fields.add i.field
    check "title" in fields
    check fields.count("name") == 2

  test "invalid field options and queries are compile errors":
    check not compiles((const f = UUIDField(primaryKey = true, null = true)))
    check not compiles((const f = CharField(maxLength = 2, minLength = 5)))
    check not compiles((const f = ForeignKey("X", onDelete = SetNull)))
    check not compiles(Person.objects.filter(nope = 1))
    check not compiles(Person.objects.filter(createdAt.icontains = "x"))
    check not compiles(Person.objects.filter(name.bogus = "x"))
    check not compiles(Person.objects.filter(any(nope = 1)))
    check not compiles(Person.objects.selectRelated("name"))
    check not compiles(Person.objects.prefetchRelated("missing"))
    check compiles(Node.objects.filter(parent.name = "root"))
    check not compiles(Node.objects.filter(parent.missing = "x"))
    check not compiles(Node.objects.filter(name.icontains.extra = "x"))
    check not compiles(Node.objects.filter(name.icontains > "x"))
    check compiles(Person.objects.filter(name.icontains = "x"))
    check compiles(Person.objects.filter(name == "A" or name == "B"))
    check compiles(Person.objects.filter(any(name = "A", name = "B")))

  test "typeFrom drops ignored columns and keeps foreign keys as ids":
    typeFrom(CreatePerson, Person.ignore(id, createdAt))
    typeFrom(FullPerson, Person)
    typeFrom(CreateTag, Tag.ignore(Tag.id))
    typeFrom(CreateNode, Node.ignore(id))
    typeFrom(Hire, Employee.ignore(id, createdAt, title, name))
    check FullPerson().id is UUID
    check FullPerson().createdAt is Time
    check not compiles(CreatePerson(name: "Ada", title: "Dr").id)
    let person = CreatePerson(name: "Ada", title: "Dr").toModel(Person)
    check person.name == "Ada"
    check person.title == "Dr"
    check CreateTag(label: "nim").label == "nim"
    check CreateNode().parentId is Option[int]
    let node = CreateNode(parentId: some(4), name: some("root")).toModel(Node)
    check node.parentId == some(4)
    check node.name == some("root")
    check Hire(salary: 7).toModel(Employee).salary == 7
    typeFrom(Bare, Employee.ignore(id, createdAt, title, name, salary))
    check Bare().toModel(Employee).salary == 1000
    check not compiles(CreatePerson(name: "Ada", title: "Dr").toModel(Base))

  test "serialize ignores named fields and writes column values":
    let person = Person(name: "Ada", title: "Dr")
    person.id = parseUUID("00112233-4455-6677-8899-aabbccddeeff")
    check person.omit(createdAt).serialize() ==
      """{"id":"00112233-4455-6677-8899-aabbccddeeff","title":"Dr","name":"Ada"}"""
    check person.omit(id).omit(createdAt).serialize() ==
      """{"title":"Dr","name":"Ada"}"""
    check person.omit([id, createdAt]).serialize() ==
      """{"title":"Dr","name":"Ada"}"""
    check @[person].omit(id, createdAt).serialize() ==
      """[{"title":"Dr","name":"Ada"}]"""
    check (none(Person)).serialize() == "null"
    var gone: Person = nil
    check gone.serialize() == "null"
    check "cache" notin person.serialize()
    let node = Node(name: some("root"))
    check node.omit(id).serialize() == """{"parentId":null,"name":"root"}"""
    let story = Story(title: "Hi", published: true)
    check story.omit(id, createdAt).serialize() == """{"title":"Hi","published":true}"""
    check $toJson(person.omit(createdAt)) == person.omit(createdAt).serialize()
    check "createdAt" in $toJson(person)
    check $toJson(node.omit(id)) == node.omit(id).serialize()
    check $toJson(story.omit(id, createdAt)) == story.omit(id, createdAt).serialize()
    check $toJson(gone) == "null"
    check "cache" notin $toJson(person)
