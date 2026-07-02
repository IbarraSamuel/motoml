export def compile-toml-parser [] {
  pixi run build
  pixi run debug_build
}

export def parse-toml [file?: path] : [
  string -> string,
  nothing -> string
] {
  let f = if $file != null {open $file --raw} else {$in} 
  $f | ./motoml_debug
}

export def compare-toml-parser [
  file?: path,  # file location for the toml content
  --expect-to: string = "pass",  # Tells the comparator what to expect from both binaries. options: {fail, pass}
] : [
  nothing -> nothing,
  string -> nothing
] {
  let should_fail = $expect_to != "pass"
  let content: string = if $in != null {$in | to text} else if file != null {open $file --raw} else {raise "input not provided!"}
  "------- toml input ------" | print
  $content | print
  "---- expected result ----" | print
  if not $should_fail {
    let $expected = $content | from toml | sort
    $expected | to json | print
  } else {
    let result = try {
      $content | from toml
      "wrong result: didn't fail" | print
    } catch {|err| $err | print}
    $result | print
  }
  "----- parser result -----" | print
  if not $should_fail {
    let result = $content | ./motoml | from json | sort
    $result | to json | print
  } else {
    let result = try {
      $content | ./motoml
      "wrong result: didn't fail" | print
    } catch {|err| $err | print}
    $result | print
  }
  # "-------------------------" | print
  # "Is exactly equal?: " + ($expected == $result | to text) | print
}
