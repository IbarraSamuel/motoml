from motoml.reflection import toml_to_struct
from motoml.read import parse_toml


comptime toml = """
name = "samuel ibarra"
age = 30
heigth = 1.68
"""
fn main() raises:
    comptime toml_value = parse_toml(toml)
    print(materialize[toml_value]())
