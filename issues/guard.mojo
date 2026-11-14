def foo[T: Movable](var x: Optional[T]) where conforms_to(T, Deinitable):
        __guard case .Some(var v) = x^ else:
            return
        _ = v^

def main():
    pass
