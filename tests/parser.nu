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

export def compare-toml-parser [file: path] {
  "------- toml input ------" | print
  open $file --raw | decode utf-8 | print
  "---- expected result ----" | print
  let expected = open ($file | str replace ".toml" ".json") | sort
  $expected | to json | print
  "----- parser result -----" | print
  let result = open $file --raw | ./motoml | from json | sort
  $result | to json | print
  "-------------------------" | print
  "Is exactly equal?: " + ($expected == $result | to text) | print
}
