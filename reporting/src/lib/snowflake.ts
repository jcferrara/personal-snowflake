// Shared Snowflake client for data loaders.
//
// Key-pair (JWT) auth, matching the SNOWFLAKE_* convention used by
// ../../extraction/.env.example and the dbt CI workflow. Reads connection
// settings from reporting/.env (via dotenv) or the process environment.

import "dotenv/config";
import snowflake from "snowflake-sdk";

// A data loader's stdout IS its output — Framework captures it verbatim,
// so nothing else may write to it. The Snowflake SDK logs through winston
// with a Console transport (stdout), and emits one line inside
// configure() *before* our settings apply, so no config option can stop
// it. Instead: keep a handle to the real stdout for our own output
// (`emit`), then point process.stdout at stderr so any library write —
// the SDK's, or a dependency's console.log — lands in Framework's loader
// diagnostics rather than corrupting the output file.
const realStdoutWrite = process.stdout.write.bind(process.stdout);

/** Write loader output. Use this instead of process.stdout.write / console.log. */
export function emit(data: string): void {
  realStdoutWrite(data);
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
(process.stdout as any).write = (...args: any[]) =>
  (process.stderr.write as (...a: any[]) => boolean)(...args);

// Belt-and-braces: also silence the SDK logger and keep its file in /tmp.
// (The published @types omit these runtime-supported keys, hence the cast.)
snowflake.configure({
  logLevel: "OFF",
  additionalLogToConsole: false,
} as snowflake.ConfigureOptions);

export interface SnowflakeConfig {
  account: string;
  username: string;
  privateKeyPath: string;
  privateKeyPass?: string;
  role: string;
  warehouse: string;
  database: string;
  schema: string;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(
      `Missing required env var ${name}. Copy reporting/.env.example to reporting/.env and fill it in.`,
    );
  }
  return value;
}

export function loadConfig(): SnowflakeConfig {
  return {
    account: requireEnv("SNOWFLAKE_ACCOUNT"),
    username: requireEnv("SNOWFLAKE_USER"),
    privateKeyPath: requireEnv("SNOWFLAKE_PRIVATE_KEY_PATH"),
    privateKeyPass: process.env.SNOWFLAKE_PRIVATE_KEY_PASSPHRASE || undefined,
    role: process.env.SNOWFLAKE_ROLE || "TRANSFORMER",
    warehouse: process.env.SNOWFLAKE_WAREHOUSE || "TRANSFORM_WH",
    database: process.env.SNOWFLAKE_DATABASE || "ANALYTICS",
    schema: process.env.SNOWFLAKE_SCHEMA || "PROD",
  };
}

/**
 * Run a single query and return all rows. Opens a fresh connection per
 * call and tears it down afterwards — fine for build-time data loaders,
 * which are short-lived one-shot processes.
 */
export async function query<T = Record<string, unknown>>(
  sqlText: string,
  binds: (string | number)[] = [],
): Promise<T[]> {
  const cfg = loadConfig();

  const connection = snowflake.createConnection({
    account: cfg.account,
    username: cfg.username,
    authenticator: "SNOWFLAKE_JWT",
    privateKeyPath: cfg.privateKeyPath,
    privateKeyPass: cfg.privateKeyPass,
    role: cfg.role,
    warehouse: cfg.warehouse,
    database: cfg.database,
    schema: cfg.schema,
  });

  await new Promise<void>((resolve, reject) => {
    connection.connect((err) => (err ? reject(err) : resolve()));
  });

  try {
    return await new Promise<T[]>((resolve, reject) => {
      connection.execute({
        sqlText,
        binds,
        complete: (err, _stmt, rows) =>
          err ? reject(err) : resolve((rows ?? []) as T[]),
      });
    });
  } finally {
    await new Promise<void>((resolve) => {
      connection.destroy(() => resolve());
    });
  }
}
