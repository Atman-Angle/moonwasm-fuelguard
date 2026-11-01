///|
fn sum_to(n : Int) -> Int {
  let mut acc = 0
  let mut i = 1
  while i <= n {
    acc = acc + i
    i = i + 1
  }
  acc
}

///|
fn collatz_steps(n : Int) -> Int {
  let mut value = n
  let mut steps = 0
  while value != 1 {
    if value % 2 == 0 {
      value = value / 2
    } else {
      value = 3 * value + 1
    }
    steps = steps + 1
  }
  steps
}

///|
fn nested_sum(rows : Int, columns : Int) -> Int {
  let mut total = 0
  let mut row = 0
  while row < rows {
    let mut column = 0
    while column < columns {
      total = total + row * columns + column
      column = column + 1
    }
    row = row + 1
  }
  total
}

///|
fn main {
  println(sum_to(100).to_string())
  println(collatz_steps(27).to_string())
  println(nested_sum(4, 5).to_string())
}
