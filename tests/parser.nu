export def compile-toml-parser [] {
  pixi run mojo build tests/stdin_parser.mojo
}

export def parse-toml [file: path] {
  open $file --raw | ./stdin_parser
}

export def compare-toml-parser [file: path] {
  let result = parse-toml $file | from json
  let expected = open ($file | str replace ".toml" ".json")
  "----- parser result -----" | print
  $result | to json | print
  "---- expected result ----" | print
  $expected | to json | print
  "-------------------------" | print
}
