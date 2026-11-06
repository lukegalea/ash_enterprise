# Credential registry OpenAPI document (synthetic)

`openapi.json` is **synthetic**: it was written for this template, it is MIT-licensed with
the rest of the repository, and no real registry publishes it. It stands in for the file you
would vendor from a real provider.

`AshEnterprise.Credentialing.RegistryApi` pins it by sha-256 (`spec_sha256`), and compilation
fails when the file and the pin disagree or when a declared operation is not in the document.

## Re-pinning

1. Replace or edit `openapi.json`.
2. Review the diff against the declarations in `registry_api.ex`.
3. Re-check each operation, then move the pin:

   ```bash
   sha256sum priv/vendor/credential_registry/openapi.json
   ```

Never update the pin alone: the pin exists so a change to the document is read before it is
accepted.
