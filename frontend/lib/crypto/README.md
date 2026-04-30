This folder is the cryptographic core. **Do not edit anything here unless you know what youre doing**

A wrong byte, the wrong order, the wrong nonce reuse ,and the entire app's
endtoend encryption breaks. You will not see any error. The
ciphertext just stops being safe

## Rules

 **Pure Dart only.** No `package:flutter/...` imports. The layering test
  (`test/architecture/layering_test.dart`) fails the build if you add one
**No I/O.** No HTTP, no storage, no logging. Bytes in, bytes out
 **Every public function has a known answer test (KAT)** that locks its
  output bytes against a fixed input. Dont modify a function without
  updating the KAT and dont update the KAT without understanding why
  the bytes changed
**Never log secret material.** Keys, plaintexts, intermediate values
  must not reach `print`, `debugPrint`, or any sink


## Talk first

If a UI or data layer change makes you want to "just add a small helper
here" just stop and ask. Almost every time, the helper belongs in `domain/`
or `data/` instead
