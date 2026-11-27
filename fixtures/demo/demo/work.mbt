///|
pub fn short_loop(n : Int32) -> Int32 {
  let mut i = 0
  let mut total = 0
  while i < n {
    total = total + i
    i = i + 1
  }
  total
}

///|
pub fn long_loop(n : Int32) -> Int32 {
  let mut i = 0
  let mut total = 0
  while i < n {
    total = total + ((i * i) ^ (i >> 2))
    i = i + 1
  }
  total
}

///|
pub fn forever() -> Unit {
  while true {

  }
}

///|
pub fn recurse(n : Int32) -> Int32 {
  if n <= 0 {
    0
  } else {
    n ^ recurse(n - 1)
  }
}
