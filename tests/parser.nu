export def compile-toml-parser [] {
  pixi run mojo build tests/stdin_parser.mojo
}

export def parse-toml [file: path] {
  open $file --raw | ./stdin_parser
}

