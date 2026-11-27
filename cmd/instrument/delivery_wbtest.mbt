///|
async test "partial report staging failure leaves both final paths unused" {
  let dir = @aio.tmpdir(prefix="fuelguard-s15-partial")
  let output = dir + "/out.wasm"
  let report = dir + "/manifest.json"
  let injected : DeliveryOps = {
    write: async fn(file, role, bytes) {
      if role == "report" {
        file.write(bytes[:2])
        raise DeliveryError("injected partial report write")
      }
      file.write(bytes)
    },
    publish: publish_delivery_file,
  }
  let error = try {
    deliver_files(output, b"product", Some((report, b"report")), ops=injected)
    "success"
  } catch {
    DeliveryError(message) => message
    error => raise error
  }
  assert_true(error.contains("injected partial report write"))
  assert_eq(@aio.readdir(dir, include_hidden=true), [])
  // Both original destinations are available for a retry.
  deliver_files(output, b"product", Some((report, b"report")))
  assert_eq(@fs.read_file_bytes(output).unwrap(), b"product")
  assert_eq(@fs.read_file_bytes(report).unwrap(), b"report")
  @aio.remove(output)
  @aio.remove(report)
  @aio.rmdir(dir)
}

///|
async test "same-size staged corruption is detected before publication" {
  let dir = @aio.tmpdir(prefix="fuelguard-s15-corrupt")
  let injected : DeliveryOps = {
    write: async fn(file, _, _) { file.write(b"corrupt") },
    publish: publish_delivery_file,
  }
  let error = try {
    deliver_files(dir + "/out.wasm", b"product", None, ops=injected)
    "success"
  } catch {
    DeliveryError(message) => message
    error => raise error
  }
  assert_true(error.contains("temporary file contents differ"))
  assert_eq(@aio.readdir(dir, include_hidden=true), [])
  @aio.rmdir(dir)
}

///|
async test "a concurrent report creator wins and its bytes are preserved" {
  let dir = @aio.tmpdir(prefix="fuelguard-s15-race")
  let output = dir + "/out.wasm"
  let report = dir + "/manifest.json"
  let injected : DeliveryOps = {
    write: write_delivery_bytes,
    publish: async fn(staged, target) {
      if target.role == "report" {
        @aio.write_file(target.path, b"existing report", create_mode=CreateNew)
      }
      publish_delivery_file(staged, target)
    },
  }
  let error = try {
    deliver_files(output, b"product", Some((report, b"report")), ops=injected)
    "success"
  } catch {
    DeliveryError(message) => message
    error => raise error
  }
  assert_true(error.contains("report path already exists"))
  assert_eq(@fs.read_file_bytes(report).unwrap(), b"existing report")
  assert_eq(@fs.read_file_bytes(output).unwrap(), b"product")
  let names = @aio.readdir(dir, include_hidden=true)
  assert_eq(names.length(), 2)
  assert_true(names.contains("manifest.json") && names.contains("out.wasm"))
  assert_true(
    verify_delivery_manifest(b"product", b"existing report") is Err(_),
  )
  @aio.remove(output)
  @aio.remove(report)
  @aio.rmdir(dir)
}

///|
async test "changed published Wasm prevents the manifest rename" {
  let dir = @aio.tmpdir(prefix="fuelguard-s15-wasm-recheck")
  let output = dir + "/out.wasm"
  let report = dir + "/manifest.json"
  let injected : DeliveryOps = {
    write: write_delivery_bytes,
    publish: async fn(staged, target) {
      publish_delivery_file(staged, target)
      if target.role == "output" {
        @aio.write_file(target.path, b"changed")
      }
    },
  }
  let error = try {
    deliver_files(output, b"product", Some((report, b"report")), ops=injected)
    "success"
  } catch {
    DeliveryError(message) => message
    error => raise error
  }
  assert_true(error.contains("delivery bytes changed"))
  assert_eq(@fs.read_file_bytes(output).unwrap(), b"changed")
  assert_eq(@aio.readdir(dir, include_hidden=true), ["out.wasm"])
  @aio.remove(output)
  @aio.rmdir(dir)
}

///|
async test "cleanup preserves a file at a replaced staging directory path" {
  let dir = @aio.tmpdir(prefix="fuelguard-s15-cleanup-owner")
  let old_directory = dir + "/moved"
  let replacement = Ref("")
  let old_file = Ref("")
  let injected : DeliveryOps = {
    write: write_delivery_bytes,
    publish: async fn(staged, _) {
      guard staged.rev_split_once("/") is Some((parent, name)) else {
        fail("expected staging parent")
      }
      @aio.rename(parent, old_directory, replace=false)
      @aio.write_file(parent, b"unowned", create_mode=CreateNew)
      replacement.val = parent.to_owned()
      old_file.val = join_delivery_path(old_directory, name.to_owned())
      raise DeliveryError("renamed staging directory")
    },
  }
  let error = try {
    deliver_files(dir + "/out.wasm", b"product", None, ops=injected)
    "success"
  } catch {
    DeliveryError(message) => message
    error => raise error
  }
  assert_eq(error, "renamed staging directory")
  assert_eq(@fs.read_file_bytes(replacement.val).unwrap(), b"unowned")
  assert_eq(@fs.read_file_bytes(old_file.val).unwrap(), b"product")
  @aio.remove(replacement.val)
  @aio.remove(old_file.val)
  @aio.rmdir(old_directory)
  @aio.rmdir(dir)
}
