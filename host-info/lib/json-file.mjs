import { chmod, mkdir, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

/**
 * Grava JSON de forma atômica: a API lê `host-info.json` continuamente e não
 * pode enxergar um arquivo pela metade. O `rename` no mesmo diretório troca o
 * conteúdo de uma vez.
 */
export async function writeJsonAtomic(filePath, value) {
  await mkdir(dirname(filePath), { recursive: true })

  const temporaryPath = `${filePath}.tmp`
  const content = `${JSON.stringify(value)}\n`

  await writeFile(temporaryPath, content, { mode: 0o644 })
  await chmod(temporaryPath, 0o644)
  await rename(temporaryPath, filePath)
}
