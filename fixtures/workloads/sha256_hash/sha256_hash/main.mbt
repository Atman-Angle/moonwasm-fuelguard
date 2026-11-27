///|
let k_tab : FixedArray[Int] = [
  1116352408, 1899447441, -1245643825, -373957723, 961987163, 1508970993,
  -1841331548, -1424204075, -670586216, 310598401, 607225278, 1426881987,
  1925078388, -2132889090, -1680079193, -1046744716, -459576895, -272742522,
  264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
  -1740746414, -1473132947, -1341970488, -1084653625, -958395405, -710438585,
  113926993, 338241895, 666307205, 773529912, 1294757372, 1396182291,
  1695183700, 1986661051, -2117940946, -1838011259, -1564481375, -1474664885,
  -1035236496, -949202525, -778901479, -694614492, -200395387, 275423344,
  430227734, 506948616, 659060556, 883997877, 958139571, 1322822218,
  1537002063, 1747873779, 1955562222, 2024104815, -2067236844, -1933114872,
  -1866530822, -1538233109, -1090935817, -965641998,
]

///|
let h0_tab : FixedArray[Int] = [
  1779033703, -1150833019, 1013904242, -1521486534, 1359893119, -1694144372,
  528734635, 1541459225,
]

///|
fn rotr(x : Int, n : Int) -> Int {
  let u = x.reinterpret_as_uint()
  let r = (u >> n) | (u << (32 - n))
  r.reinterpret_as_int()
}

///|
fn compress(state : FixedArray[Int], w : FixedArray[Int]) -> Unit {
  for t in 16..<64 {
    let m0 = w[t - 15].reinterpret_as_uint()
    let m2 = w[t - 2].reinterpret_as_uint()
    let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (m0 >> 3).reinterpret_as_int()
    let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (m2 >> 10).reinterpret_as_int()
    w[t] = w[t - 16] + s0 + w[t - 7] + s1
  }
  let mut a = state[0]
  let mut b = state[1]
  let mut c = state[2]
  let mut d = state[3]
  let mut e = state[4]
  let mut f = state[5]
  let mut g = state[6]
  let mut h = state[7]
  for t in 0..<64 {
    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
    let ch = (e & f) ^ ((e ^ -1) & g)
    let t1 = h + s1 + ch + k_tab[t] + w[t]
    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let t2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + t1
    d = c
    c = b
    b = a
    a = t1 + t2
  }
  state[0] = state[0] + a
  state[1] = state[1] + b
  state[2] = state[2] + c
  state[3] = state[3] + d
  state[4] = state[4] + e
  state[5] = state[5] + f
  state[6] = state[6] + g
  state[7] = state[7] + h
}

///|
fn sha256_words(data : Bytes) -> FixedArray[Int] {
  let state = FixedArray::make(8, 0)
  for i in 0..<8 {
    state[i] = h0_tab[i]
  }
  let w : FixedArray[Int] = FixedArray::make(64, 0)
  let total = data.length()
  let blocks = (total + 8) / 64 + 1
  for block in 0..<blocks {
    let base = block * 64
    for i in 0..<16 {
      let o = base + i * 4
      let b0 = if o < total {
        data[o].to_int()
      } else if o == total {
        0x80
      } else {
        0
      }
      let b1 = if o + 1 < total {
        data[o + 1].to_int()
      } else if o + 1 == total {
        0x80
      } else {
        0
      }
      let b2 = if o + 2 < total {
        data[o + 2].to_int()
      } else if o + 2 == total {
        0x80
      } else {
        0
      }
      let b3 = if o + 3 < total {
        data[o + 3].to_int()
      } else if o + 3 == total {
        0x80
      } else {
        0
      }
      w[i] = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
    if block == blocks - 1 {
      w[15] = total * 8
    }
    compress(state, w)
  }
  state
}

///|
fn main {
  let data = Bytes::makei(4096, i => {
    if i % 3 == 0 {
      b'F'
    } else if i % 3 == 1 {
      b'G'
    } else {
      b'!'
    }
  })
  let mut round = 0
  let mut checksum : Int = 0
  let mut words : FixedArray[Int] = FixedArray::make(8, 0)
  while round < 32 {
    words = sha256_words(data)
    let mut index = 0
    while index < 8 {
      let u = words[index].reinterpret_as_uint()
      let b24 = ((u >> 24) & 0xffU).reinterpret_as_int()
      let b16 = ((u >> 16) & 0xffU).reinterpret_as_int()
      let b8 = ((u >> 8) & 0xffU).reinterpret_as_int()
      let b0 = (u & 0xffU).reinterpret_as_int()
      checksum = checksum + (b24 + b16 + b8 + b0)
      index = index + 1
    }
    round = round + 1
  }
  println("sha256 rounds=32 bytes=4096 checksum=" + checksum.to_string())
  let line = "words=" + words[0].to_string()
  let line = line + " " + words[1].to_string()
  let line = line + " " + words[2].to_string()
  let line = line + " " + words[3].to_string()
  let line = line + " " + words[4].to_string()
  let line = line + " " + words[5].to_string()
  let line = line + " " + words[6].to_string()
  let line = line + " " + words[7].to_string()
  println(line)
}
