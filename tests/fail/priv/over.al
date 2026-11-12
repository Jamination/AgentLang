enum K { I8, F64 }
priv fn is_int(k: K) -> bool { k == I8 }
priv fn size(k: K) -> i64 { if k == I8 { 1 } else { 8 } }
fn over_use() -> bool { is_int(K.I8) && size(K.F64) == 8 }
