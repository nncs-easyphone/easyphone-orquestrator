import { readFile } from 'node:fs/promises'

import { collectDockerInfo } from './lib/docker-info.mjs'
import { parseServiceAccount, sendSystemReport } from './lib/firebase-report.mjs'
import { writeJsonAtomic } from './lib/json-file.mjs'
import { collectHostIdentity, collectServerInfo } from './lib/server-info.mjs'

const OUTPUT_DIRECTORY = '/host-info'
const HOST_INFO_FILE = `${OUTPUT_DIRECTORY}/host-info.json`
const SYSTEM_REPORT_FILE = `${OUTPUT_DIRECTORY}/system-report.json`
const VERSION_FILE = '/orchestrator/VERSION'
const COMPOSE_PROJECT = 'easyphone'

const COLLECT_INTERVAL_MS = 60_000
const REPORT_INTERVAL_MS = 10 * 60_000

const firebaseUrl = process.env.FIREBASE_URL?.trim() ?? ''
const firebaseServiceAccount = process.env.FIREBASE_SERVICE_ACCOUNT?.trim() ?? ''
const licenseClientId = process.env.LICENSE_CLIENT_ID?.trim() ?? ''
const hardwareId = process.env.LICENSE_HARDWARE_ID?.trim() ?? ''

let reportingEnabled = Boolean(
  firebaseUrl && firebaseServiceAccount && licenseClientId && hardwareId,
)
let serviceAccount = null
let lastReportAt = 0

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error)
}

if (reportingEnabled) {
  try {
    serviceAccount = parseServiceAccount(firebaseServiceAccount)
  } catch (error) {
    reportingEnabled = false
    console.error(`[host-info] relatório desativado: ${errorMessage(error)}`)
  }
} else {
  console.warn(
    '[host-info] relatório para o Firebase desativado: '
      + 'FIREBASE_URL, FIREBASE_SERVICE_ACCOUNT, LICENSE_CLIENT_ID e LICENSE_HARDWARE_ID são obrigatórios',
  )
}

async function readOrchestratorVersion() {
  try {
    const value = (await readFile(VERSION_FILE, 'utf8')).trim()
    return value || 'unknown'
  } catch {
    return 'unknown'
  }
}

async function collectDockerSafely() {
  try {
    return await collectDockerInfo({ project: COMPOSE_PROJECT })
  } catch (error) {
    return {
      available: false,
      engineVersion: null,
      apiVersion: null,
      composeProject: COMPOSE_PROJECT,
      containers: [],
      images: [],
      error: errorMessage(error),
    }
  }
}

async function buildSystemReport() {
  const identity = await collectHostIdentity()
  const [server, docker, version] = await Promise.all([
    collectServerInfo(identity),
    collectDockerSafely(),
    readOrchestratorVersion(),
  ])

  return {
    schemaVersion: 1,
    reportedAt: new Date().toISOString(),
    orchestrator: { version },
    server,
    docker,
  }
}

async function writeHostInfo() {
  const identity = await collectHostIdentity()
  await writeJsonAtomic(HOST_INFO_FILE, identity)
}

async function reportSystem() {
  const report = await buildSystemReport()
  await writeJsonAtomic(SYSTEM_REPORT_FILE, report)

  if (!reportingEnabled || !serviceAccount) {
    console.log('[host-info] relatório local atualizado (envio ao Firebase desativado)')
    return
  }

  const status = await sendSystemReport({
    firebaseUrl,
    serviceAccount,
    licenseClientId,
    hardwareId,
    report,
  })

  console.log(
    `[host-info] relatório enviado (${status}); versão=${report.orchestrator.version}; `
      + `containers=${report.docker.containers.length}; imagens=${report.docker.images.length}`,
  )
}

async function tick() {
  try {
    await writeHostInfo()
  } catch (error) {
    console.error(`[host-info] falha ao gravar host-info.json: ${errorMessage(error)}`)
  }

  const now = Date.now()
  if (lastReportAt !== 0 && now - lastReportAt < REPORT_INTERVAL_MS) return

  lastReportAt = now
  try {
    await reportSystem()
  } catch (error) {
    console.error(`[host-info] falha ao gerar/enviar system-report: ${errorMessage(error)}`)
  }
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

process.on('SIGTERM', () => process.exit(0))
process.on('SIGINT', () => process.exit(0))

console.log(
  `[host-info] iniciando; coleta a cada ${COLLECT_INTERVAL_MS / 1000}s; `
    + `relatório a cada ${REPORT_INTERVAL_MS / 60_000}min`,
)

for (;;) {
  await tick()
  await sleep(COLLECT_INTERVAL_MS)
}
