# Authentication Flow

The switch Web UI uses **client-side RSA encryption** for login.
Passwords are **never sent in plaintext** — the browser JavaScript fetches a public key, encrypts the password, Base64-encodes it, then URL-encodes that string before sending.

## Steps

1. **Fetch RSA modulus**
   - `GET /cgi/get.cgi?cmd=home_login`
   - Response includes `data.modulus` (hex string).
   - The exponent is always `0x10001`.

2. **Encrypt password**
   - Create an RSA public key with `(modulus, exponent)`.
   - Encrypt the password using **PKCS#1 v1.5 padding**.
   - Base64-encode the ciphertext.
   - URL-encode the result (`+ → %2B`, `/ → %2F`, `= → %3D`).

3. **Send loginAuth**
   - `POST /cgi/set.cgi?cmd=home_loginAuth`
   - Payload:
     ```
     _ds=1&username=<USERNAME>&password=<ENCODED_PWD>&_de=1
     ```
   - This always returns `"status": "ok"`, regardless of password validity.

4. **Poll login status**
   - `GET /cgi/get.cgi?cmd=home_loginStatus`
   - Possible responses:
     - `{"status": "ok"}` → login succeeded
     - `{"status": "fail", "failReason": ...}` → login failed
     - `{"status": "authing"}` → still in progress

## Notes
- Polling `home_loginStatus` is mandatory — the loginAuth response cannot be trusted.
- Once `"status": "ok"`, the session cookie can be used for further API requests.

# Packages
## Why not use lua-http?
Normally, we’d use lua-http for HTTP requests, since it’s modern, async, and has a clean API.
However, the embedded web server on this switch (Hydra/0.1.8) produces non-standard HTTP/1.1 responses:
- Headers are very minimal (Date, Server, Accept-Ranges, Connection)
- The parser in lua-http is strict and expects RFC-compliant encodings
- Hydra’s responses trigger errors like: `read_header: Invalid or incomplete multibyte or wide character`

This makes lua-http unusable against the device.

### Why cqueues.socket works
Instead of relying on a strict HTTP parser, we open a raw TCP socket using `cqueues.socket` and construct our own HTTP/1.0 request strings.
We then read the response stream manually, split headers from the body, and parse the JSON ourselves.

This approach bypasses the strict parser entirely, making it tolerant of Hydra’s “imperfect” HTTP responses while still being lightweight and predictable.

## Why we couldn’t use `luaossl`

Originally, the plan was to use [`luaossl`](https://github.com/wahern/luaossl) because it provides Lua bindings to OpenSSL, including support for RSA key construction and PKCS#1 v1.5 encryption.
In theory, this would let us stay fully in Lua without shelling out to external tools.

In practice, it didn’t work for several reasons:

1. **Incomplete API coverage**
   - `luaossl` can read keys from PEM/DER files, but its documented `pkey.new{ n=..., e=... }` path for constructing an RSA key directly from modulus/exponent doesn’t work as expected (returned errors or `nil` in tests).
   - Methods like `pkey:encrypt("...", "rsa_pkcs1v15")` either aren’t exposed or don’t behave consistently with OpenSSL’s CLI defaults.

2. **Interoperability issues**
   - Even when keys could be loaded, the ciphertext produced by `luaossl` did not match what the switch expected.
   - The mismatch was likely caused by differences in padding defaults or wire encoding (browser JS and `openssl pkeyutl` agreed, but `luaossl` diverged).

3. **Maintenance / support risk**
   - `luaossl` is a thin wrapper around OpenSSL. When behavior diverges from the CLI, you end up debugging OpenSSL internals.
   - For this use case (encrypting a password like the browser), relying on the CLI is simpler and guaranteed to match the device.

---

## Why we use the `openssl` CLI instead

The working solution is to generate the public key and ciphertext the same way as the browser and OpenSSL CLI:

- Build an ASN.1 description from modulus/exponent
- Use `openssl asn1parse` and `openssl rsa` to generate a PEM
- Run `openssl pkeyutl` with `-pkeyopt rsa_padding_mode:pkcs1`
- Base64 + URL encode in Lua

This guarantees the ciphertext is **byte-for-byte identical** to the browser’s implementation and avoids padding/encoding pitfalls we hit with `luaossl`.

---

**Summary:**
- `luaossl` looked promising but couldn’t reproduce the exact `openssl pkeyutl` behavior required by the switch login.
- To ensure compatibility, we now call the OpenSSL CLI from Lua using `fibers.exec`.
