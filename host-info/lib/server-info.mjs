import { readFile, statfs } from 'node:fs/promises'
import os from 'node:os'

const OS_RELEASE_FILE = '/host/os-release'
const PROC_UPTIME_FILE = '/host/proc/uptime'
const PROC_MEMINFO_FILE = '/host/proc/meminfo'
const HOST_ROOT = '/host/rootfs'

const KILOBYTE = 1024

function toFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

async function readText(filePath) {
  try {
    return await readFile(filePath, 'utf8')
  } catch {
    return null
  }
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}

export async function readOperatingSystem() {
  const content = await readText(OS_RELEASE_FILE)
  if (!content) return `${os.type()} ${os.release()}`.trim()

  const match = content.match(/^PRETTY_NAME=(.*)$/m)
  if (!match) return `${os.type()} ${os.release()}`.trim()

  return match[1].trim().replace(/^"(.*)"$/, '$1')
}

/**
 * Mesmas regras do antigo `collect.sh`: IPv4, sem loopback e sem as interfaces
 * que o Docker cria no host (docker0, bridges br-* e pares veth).
 */
export function readNetworkInterfaces() {
  const interfaces = os.networkInterfaces()
  const result = []

  for (const [name, addresses] of Object.entries(interfaces)) {
    if (!addresses) continue
    if (name === 'lo' || /^(docker|br-|veth)/.test(name)) continue

    for (const address of addresses) {
      const isIpv4 = address.family === 'IPv4' || address.family === 4
      if (!isIpv4 || address.internal) continue
      result.push({ name, address: address.address })
    }
  }

  return result
}

export async function collectHostIdentity() {
  return {
    hostname: os.hostname(),
    operatingSystem: await readOperatingSystem(),
    network: readNetworkInterfaces(),
    collectedAt: new Date().toISOString(),
  }
}

async function readUptimeSeconds() {
  const content = await readText(PROC_UPTIME_FILE)
  if (content) {
    const value = Number.parseFloat(content.trim().split(/\s+/)[0])
    if (Number.isFinite(value) && value >= 0) return Math.round(value)
  }

  return Math.round(os.uptime())
}

function parseMeminfo(content) {
  const values = {}

  for (const line of content.split('\n')) {
    const match = line.match(/^([A-Za-z_()]+):\s+(\d+)/)
    if (!match) continue
    values[match[1]] = Number.parseInt(match[2], 10) * KILOBYTE
  }

  return values
}

async function readMemory() {
  const content = await readText(PROC_MEMINFO_FILE)

  if (content) {
    const values = parseMeminfo(content)
    const totalBytes = toFiniteNumber(values.MemTotal)
    const availableBytes = toFiniteNumber(values.MemAvailable) ?? toFiniteNumber(values.MemFree)
    const swapTotalBytes = toFiniteNumber(values.SwapTotal) ?? 0
    const swapFreeBytes = toFiniteNumber(values.SwapFree) ?? 0

    if (totalBytes !== null && availableBytes !== null) {
      return {
        memory: {
          totalBytes,
          availableBytes,
          usedBytes: Math.max(0, totalBytes - availableBytes),
        },
        swap: {
          totalBytes: swapTotalBytes,
          usedBytes: Math.max(0, swapTotalBytes - swapFreeBytes),
        },
      }
    }
  }

  const totalBytes = os.totalmem()
  const availableBytes = os.freemem()

  return {
    memory: {
      totalBytes,
      availableBytes,
      usedBytes: Math.max(0, totalBytes - availableBytes),
    },
    swap: {
      totalBytes: 0,
      usedBytes: 0,
    },
  }
}

async function readDisk() {
  for (const mount of [HOST_ROOT, '/']) {
    try {
      const stats = await statfs(mount)
      const totalBytes = stats.bsize * stats.blocks
      const availableBytes = stats.bsize * stats.bavail

      if (totalBytes <= 0) continue

      return {
        mount: '/',
        totalBytes,
        availableBytes,
        usedBytes: Math.max(0, totalBytes - availableBytes),
      }
    } catch {
      // Tenta o próximo mount; sem host root, o overlay do container é o que há.
    }
  }

  return null
}

function readCpuTimes() {
  let idle = 0
  let total = 0

  for (const cpu of os.cpus()) {
    for (const value of Object.values(cpu.times)) total += value
    idle += cpu.times.idle
  }

  return { idle, total }
}

async function readCpuUsage() {
  const start = readCpuTimes()
  await sleep(300)
  const end = readCpuTimes()

  const idleDifference = end.idle - start.idle
  const totalDifference = end.total - start.total
  if (totalDifference <= 0) return null

  const usage = 100 - (idleDifference / totalDifference) * 100
  if (!Number.isFinite(usage)) return null

  return Math.max(0, Math.min(100, Math.round(usage)))
}

export async function collectServerInfo(identity) {
  const hostIdentity = identity ?? await collectHostIdentity()
  const cpus = os.cpus()
  const { memory, swap } = await readMemory()
  const load = os.loadavg()

  return {
    hostname: hostIdentity.hostname,
    operatingSystem: hostIdentity.operatingSystem,
    kernel: os.release(),
    architecture: os.arch(),
    uptimeSeconds: await readUptimeSeconds(),
    loadAverage: {
      one: load[0] ?? 0,
      five: load[1] ?? 0,
      fifteen: load[2] ?? 0,
    },
    cpu: {
      model: cpus[0]?.model ?? 'unknown',
      logicalCores: cpus.length,
      speedMHz: cpus[0]?.speed ?? null,
      usagePercent: await readCpuUsage(),
    },
    memory,
    swap,
    disk: await readDisk(),
    network: hostIdentity.network,
  }
}
