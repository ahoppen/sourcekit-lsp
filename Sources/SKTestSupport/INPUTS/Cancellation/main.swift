class Foo {
  func slow(x: Invalid1, y: Invalid2) {
    x / y / x / y / x / y / x / y . /*slowLoc*/
  }

  struct Foo {
    let fooMember: String
  }

  func fast(a: Foo) {
    a . /*fastLoc*/
  }
}
