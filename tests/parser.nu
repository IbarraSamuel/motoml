export def compile-toml-parser [] {
  pixi run mojo build tests/stdin_parser.mojo
}

export def parse-toml [file: path] {
  open $file --raw | ./stdin_parser
}

export def compare-toml-parser [file: path] {
  "---- expected result ----" | print
  let expected = open ($file | str replace ".toml" ".json") | sort
  $expected | to json | print
  "----- parser result -----" | print
  let result = parse-toml $file | from json | sort
  $result | to json | print
  "-------------------------" | print
}
