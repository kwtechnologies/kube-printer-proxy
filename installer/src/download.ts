import { createWriteStream } from "fs";
import { mkdir } from "fs/promises";
import { dirname } from "path";
import { Writable } from "stream";

export async function downloadFile(url: string, dest: string): Promise<void> {
  await mkdir(dirname(dest), { recursive: true });

  const res = await fetch(url, { redirect: "follow" });
  if (!res.ok) {
    throw new Error(`Download failed: ${res.status} ${res.statusText} (${url})`);
  }
  if (!res.body) {
    throw new Error(`No response body from ${url}`);
  }

  const writer = createWriteStream(dest);
  // @ts-expect-error ReadableStream -> Node writable pipe
  await res.body.pipeTo(Writable.toWeb(writer));
}

export async function getLatestTag(ghRepo: string): Promise<string> {
  const res = await fetch(
    `https://api.github.com/repos/${ghRepo}/releases/latest`,
  );
  if (!res.ok) {
    throw new Error(`Failed to fetch latest release: ${res.status}`);
  }
  const data = (await res.json()) as { tag_name: string };
  return data.tag_name;
}
