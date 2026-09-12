export interface InstalledRelease {
  readonly directory: string;
  readonly release: {
    readonly executable: string;
  };
}

export interface InstallOptions {
  readonly cacheRoot?: string;
  readonly signal?: AbortSignal;
}

export function defaultCacheRoot(
  platform?: NodeJS.Platform,
  environment?: NodeJS.ProcessEnv,
): string;

export function ensureInstalled(options?: InstallOptions): Promise<InstalledRelease>;
