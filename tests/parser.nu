export def compile-toml-parser [] {
  pixi run mojo build -D LOG=1 tests/stdin_parser.mojo -o parser-w-logs
  pixi run mojo build tests/stdin_parser.mojo -o parser
}

export def parse-toml [file?: path] : [
  string -> string,
  nothing -> string
] {
  let f = if $file != null {open $file --raw} else {$in} 
  $f | ./parser-w-logs
}

export def compare-toml-parser [file: path] {
  "------- toml input ------" | print
  open $file --raw | decode utf-8 | print
  "---- expected result ----" | print
  let expected = open ($file | str replace ".toml" ".json") | sort
  $expected | to json | print
  "----- parser result -----" | print
  let result = open $file --raw | ./parser | from json | sort
  $result | to json | print
  "-------------------------" | print
  "Is exactly equal?: " + ($expected == $result | to text) | print
}
