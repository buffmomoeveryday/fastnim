import std/assertions

import fastnim

doAssert slugify(" Joel is a slug ") == "joel-is-a-slug"
doAssert slugify("Joel is a slug") == "joel-is-a-slug"
doAssert slugify("--hello world--") == "hello-world"
doAssert slugify("hello__world") == "hello__world"
doAssert slugify("__hello__") == "hello"
doAssert slugify("Café Menu") == "cafe-menu"
doAssert slugify("Mílos") == "milos"
doAssert slugify("a  b---c") == "a-b-c"
doAssert slugify("Hello, World!") == "hello-world"
doAssert slugify("") == ""
doAssert slugify("   ") == ""
doAssert slugify("---") == ""

doAssert slugify("你好 World") == "world"
doAssert slugify("你好 World", allowUnicode = true) == "你好-world"
doAssert slugify("Πειραιάς", allowUnicode = true).len > 0
doAssert slugify("Πειραιάς") == ""

doAssert slugify("Book Title: The Sequel") == "book-title-the-sequel"
