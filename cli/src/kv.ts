#!/usr/bin/env node
import { runKv, VaultCliError } from "./vault.js";

runKv(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (error) => {
    if (error instanceof VaultCliError) {
      process.stderr.write(error.message + "\n");
      process.exit(error.code);
    }
    process.stderr.write(`kv: ${(error as Error)?.stack ?? error}\n`);
    process.exit(1);
  }
);
