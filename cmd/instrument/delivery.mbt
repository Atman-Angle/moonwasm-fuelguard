///|
priv suberror DeliveryError {
  DeliveryError(String)
}

///|
priv struct DeliveryTarget {
  parent : String
  name : String
  path : String
  role : String
}

///|
priv struct StagedFile {
  directory : String
  directory_name : String
  path : String
  mut created : Bool
  mut published : Bool
}

///|
priv struct DeliveryOps {
  write : async (@aio.File, String, Bytes) -> Unit
  publish : async (String, DeliveryTarget) -> Unit
}

///|
fn join_delivery_path(parent : String, name : String) -> String {
  if parent.has_suffix("/") {
    parent + name
  } else {
    parent + "/" + name
  }
}

///|
async fn delivery_target(
  raw_path : String,
  role : String,
  windows : Bool,
) -> DeliveryTarget {
  if raw_path.contains_char('\u{0}') {
    raise DeliveryError("invalid \{role} path")
  }
  let path = if windows {
    raw_path.replace_all(old="\\", new="/")
  } else {
    raw_path
  }
  let (parent, name) = match path.rev_split_once("/") {
    // Include the separator so roots (e.g. C:/) keep their meaning.
    Some((parent, name)) => (parent.to_owned() + "/", name.to_owned())
    None => (".", path)
  }
  if name == "" ||
    name == "." ||
    name == ".." ||
    (
      windows &&
      (name.has_suffix(".") || name.has_suffix(" ") || name.contains(":"))
    ) {
    raise DeliveryError("invalid \{role} file name: '\{raw_path}'")
  }
  let parent = @aio.realpath(parent) catch {
    error =>
      raise DeliveryError(
        "cannot resolve \{role} directory for '\{raw_path}': \{error}",
      )
  }
  let parent = if windows {
    parent.replace_all(old="\\", new="/")
  } else {
    parent
  }
  let path = join_delivery_path(parent, name)
  { parent, name, path, role, }
}

///|
fn could_be_windows_short_name(name : String) -> Bool {
  let (stem, extension) = match name.split_once(".") {
    Some((stem, extension)) => (stem, extension)
    None => (name[:], ""[:])
  }
  guard stem.length() <= 8 &&
    extension.length() <= 3 &&
    stem.to_owned().rev_split_once("~") is Some((prefix, suffix)) &&
    prefix.length() > 0 &&
    suffix.length() > 0 else {
    return false
  }
  suffix.iter().all(fn(char) { char >= '0' && char <= '9' })
}

///|
fn delivery_name_conflict(
  output : DeliveryTarget,
  report : DeliveryTarget,
  windows : Bool,
) -> String? {
  if output.name == report.name ||
    (windows && output.name.to_upper() == report.name.to_upper()) {
    Some("--report must differ from the output path")
  } else if windows &&
    (
      could_be_windows_short_name(output.name) ||
      could_be_windows_short_name(report.name)
    ) {
    // A newly published Windows file may acquire a DOS alias only at rename.
    Some("ambiguous Windows short name in output/report paths; use long names")
  } else {
    None
  }
}

///|
async fn require_distinct_directories(
  report : DeliveryTarget,
  stage : StagedFile,
  conflict : String,
) -> Unit {
  // A bind mount can alias the same directory with a different canonical
  // path. A random directory just created in the output parent is a probe.
  let probe = join_delivery_path(report.parent, stage.directory_name)
  try @aio.kind(probe, follow_symlink=false) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => ()
    error => raise error
  } noraise {
    _ => raise DeliveryError(conflict)
  }
}

///|
async fn require_new_target(target : DeliveryTarget) -> Unit {
  try @aio.kind(target.path, follow_symlink=false) catch {
    @os_error.OSError(_) as error if error.is_ENOENT() => ()
    error =>
      raise DeliveryError(
        "cannot check \{target.role} path '\{target.path}': \{error}",
      )
  } noraise {
    _ =>
      raise DeliveryError(
        "\{target.role} path already exists: '\{target.path}'",
      )
  }
}

///|
async fn write_delivery_bytes(
  file : @aio.File,
  _role : String,
  bytes : Bytes,
) -> Unit {
  file.write(bytes)
}

///|
async fn publish_delivery_file(
  staged : String,
  target : DeliveryTarget,
) -> Unit {
  @aio.rename(staged, target.path, replace=false) catch {
    @os_error.OSError(_) as error if error.is_EEXIST() =>
      raise DeliveryError(
        "\{target.role} path already exists: '\{target.path}'",
      )
    error =>
      raise DeliveryError(
        "cannot publish \{target.role} '\{target.path}' without replacement: \{error}",
      )
  }
}

///|
let delivery_ops : DeliveryOps = {
  write: write_delivery_bytes,
  publish: publish_delivery_file,
}

///|
async fn stage_delivery_file(
  target : DeliveryTarget,
  bytes : Bytes,
  staged : Array[StagedFile],
  ops : DeliveryOps,
) -> StagedFile {
  guard @env.rand(32) is Some(random) else {
    raise DeliveryError("host cannot generate temporary paths")
  }
  // Keep the staging entry on the destination filesystem. A POSIX peer with
  // access to the destination directory cannot enter this private directory.
  let directory_name = ".fuelguard-\{hex_bytes(random[:16].iter())}.tmp"
  let directory = join_delivery_path(target.parent, directory_name)
  @aio.mkdir(directory, permission=0o700, allow_exist=false) catch {
    error =>
      raise DeliveryError(
        "cannot create staging directory for \{target.role} '\{target.path}': \{error}",
      )
  }
  let path = join_delivery_path(directory, hex_bytes(random[16:].iter()))
  let temporary = {
    directory,
    directory_name,
    path,
    created: false,
    published: false,
  }
  staged.push(temporary)
  try {
    let file = @aio.open(
      path,
      mode=ReadWrite,
      create_mode=CreateNew,
      permission=0o666,
    )
    temporary.created = true
    defer file.close()
    (ops.write)(file, target.role, bytes)
    file.sync()
    if !file_has_bytes(file, bytes) {
      raise DeliveryError("temporary file contents differ from encoded bytes")
    }
  } catch {
    DeliveryError(message) =>
      raise DeliveryError(
        "cannot stage \{target.role} '\{target.path}': \{message}",
      )
    error =>
      raise DeliveryError(
        "cannot stage \{target.role} '\{target.path}': \{error}",
      )
  }
  temporary
}

///|
async fn file_has_bytes(file : @aio.File, expected : Bytes) -> Bool {
  file.kind() == @aio.Regular &&
  file.size() == expected.length().to_int64() &&
  file.read_exactly_at(expected.length(), position=0L) == expected
}

///|
async fn require_delivery_bytes(path : String, expected : Bytes) -> Unit {
  if @aio.kind(path, follow_symlink=false) != @aio.Regular {
    raise DeliveryError("delivery path changed: '\{path}'")
  }
  let file = @aio.open(path, mode=ReadOnly)
  defer file.close()
  if !file_has_bytes(file, expected) {
    raise DeliveryError("delivery bytes changed: '\{path}'")
  }
}

///|
async fn cleanup_staged(temporary : StagedFile) -> Unit noraise {
  try {
    // Never traverse a replaced staging directory symlink or remove unknown
    // entries. A nonempty directory is left for inspection.
    if @aio.kind(temporary.directory, follow_symlink=false) != @aio.Directory {
      return
    }
    if temporary.created && !temporary.published {
      try {
        if @aio.kind(temporary.path, follow_symlink=false) == @aio.Regular {
          @aio.remove(temporary.path)
        }
      } catch {
        @os_error.OSError(_) as missing if missing.is_ENOENT() => ()
        error => raise error
      }
    }
    @aio.rmdir(temporary.directory)
  } catch {
    @os_error.OSError(_) as missing if missing.is_ENOENT() => ()
    error =>
      println(
        "instrument: cannot clean staging directory '\{temporary.directory}': \{error}",
      )
  }
}

///|
async fn deliver_files(
  output_path : String,
  wasm : Bytes,
  report : (String, Bytes)?,
  ops~ : DeliveryOps = delivery_ops,
) -> Unit {
  let windows = !@aio.realpath(".").has_prefix("/")
  let output = delivery_target(output_path, "output", windows)
  require_new_target(output)
  let report = match report {
    Some((path, bytes)) => {
      let target = delivery_target(path, "report", windows)
      let conflict = delivery_name_conflict(output, target, windows)
      if conflict is Some(message) &&
        (
          output.parent == target.parent ||
          (windows && output.parent.to_upper() == target.parent.to_upper())
        ) {
        raise DeliveryError(message)
      }
      require_new_target(target)
      Some((target, bytes, conflict))
    }
    None => None
  }
  let staged : Array[StagedFile] = []
  defer @async.protect_from_cancel(() => {
    for temporary in staged {
      cleanup_staged(temporary)
    }
  })
  let output_file = stage_delivery_file(output, wasm, staged, ops)
  let report_file = match report {
    Some((target, bytes, conflict)) => {
      if conflict is Some(message) {
        require_distinct_directories(target, output_file, message)
      }
      Some((target, bytes, stage_delivery_file(target, bytes, staged, ops)))
    }
    None => None
  }
  (ops.publish)(output_file.path, output)
  output_file.published = true
  if report_file is Some((target, bytes, temporary)) {
    require_delivery_bytes(temporary.path, bytes)
    require_delivery_bytes(output.path, wasm)
    (ops.publish)(temporary.path, target)
    temporary.published = true
    require_delivery_bytes(target.path, bytes)
  } else {
    require_delivery_bytes(output.path, wasm)
  }
}
